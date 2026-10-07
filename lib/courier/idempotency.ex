defmodule Courier.Idempotency do
  @moduledoc """
  The context over `idempotency_keys`: claiming a key, and either storing the
  answer or giving it back.

  Core's `docs/openapi-conventions.md` §Idempotency is the specification. This
  module implements the storage half of it; `CourierWeb.Plugs.Idempotency` is the
  half that reads a header and answers a request, and the two are split so the
  arithmetic can be tested without a plug pipeline and the wiring can be tested
  without a database.

  ## Why the claim is written before the work

  A key that is only recorded *after* the action cannot prevent anything. Two
  requests with one key would both run, both mutate, and both try to store — and
  the second store would either overwrite the first or be rejected, after the
  damage. So `claim/1` is called before the controller and `complete/4` after it,
  and the row exists in between in the `in_flight` state, which is what a second
  request with the same key finds.

  ## Why the unique index is read, and not `ON CONFLICT DO NOTHING`

  The first draft of this module used `on_conflict: :nothing` and looked for a
  returned row with a nil `id`, which is how Ecto reports "nothing was inserted".
  That does not work against a schema whose primary key is
  `@primary_key {:id, Ecto.UUID, autogenerate: true}`, and it fails silently:

  **the id is generated into the changeset before the query runs**, so on a real
  conflict Ecto hands back a struct carrying a fresh, well-formed uuid that was
  never inserted — and `__meta__.state` on that struct is `:loaded` too. Measured
  rather than assumed: two inserts of one triple, the second conflicting, return
  two different ids and leave one row, so nothing on the struct can answer "did
  this insert?".

  So the claim takes the constraint error, and `refusal/1` matches it on the index
  **by name**. The unique index is what makes the claim at the database rather
  than in a check a caller might forget, and it is the same index either way —
  this is only about how the losing insert finds out that it lost.

  ## Expiry is enforced on the way in, not by a job

  core says 24 hours. Nothing sweeps the table on a timer — a second supervision
  tree for a table this size is a service that can be down — so `claim/1` deletes
  the expired rows for the triple it is about to claim, immediately before the
  insert. A key the caller has not used for a day behaves as though it had never
  been used, which is what "retention: 24 hours" means, and the sweep only ever
  runs on a key somebody is actually presenting.

  ## What is stored, and what is not

  Only a 2xx is stored, and `release/1` deletes the claim for anything else. The
  reason is that a stored 4xx pins a *caller's* mistake for a day — a client that
  sent a bad url, fixed it and retried with the same key would get 409
  `idempotency_key_reused` rather than its new answer — and a stored 5xx pins a
  *courier's* transient failure for a day, which turns a blip into an outage
  nobody can retry their way out of. A retry of a failed request re-running it is
  always safe, because nothing was committed. Only a successful mutation is worth
  replaying, so only a successful mutation is replayed.
  """

  import Ecto.Query, warn: false

  alias Courier.IdempotencyKey
  alias Courier.Repo

  @retention_hours 24

  # The index that decides whether a claim was taken. Named in one place because
  # it is named in two — the migration that creates it and the changeset that
  # declares it — and a third spelling in `refusal/1` is a claim that silently
  # stops being `:taken`.
  @claim_index "idempotency_keys_account_id_endpoint_key_index"

  @typedoc "Why a claim did not happen."
  @type refusal :: :taken | {:error, Ecto.Changeset.t()}

  @doc """
  The retention window, in hours. core's number, named once so a document and this
  module cannot disagree about it silently.
  """
  @spec retention_hours() :: pos_integer()
  def retention_hours, do: @retention_hours

  @doc """
  Claims `(account_id, endpoint, idempotency_key)` for `request_hash`.

  `{:ok, key}` means the caller owns the key and must later call `complete/4` or
  `release/1`. `{:error, :taken}` means someone else owns it — concurrently or
  earlier — and the caller must read the row with `fetch/3` to find out which of
  the three outcomes applies.
  """
  @spec claim(map()) :: {:ok, IdempotencyKey.t()} | {:error, refusal()}
  def claim(attrs) do
    # The expired-row sweep and the insert are deliberately **not** in one
    # transaction together, and that is a considered choice rather than an
    # omission. Wrapping them costs a real thing: `Repo.transaction/1` replaces whatever its
    # function returns with `:rollback` when that function returns an error, so a
    # `{:error, :taken}` would arrive as a bare `{:error, :rollback}` and the
    # reason would have to be carried out of the function in a variable or a
    # process dictionary to survive its own transaction.
    #
    # What atomicity would buy here is nothing. The sweep deletes rows that are
    # already past their retention window, so deleting them is correct whether or
    # not this insert then wins — and if the insert loses, the rows it swept were
    # rows the winner has no use for either. The one interleaving worth checking
    # is two requests sweeping and inserting the same expired row, and it is safe:
    # one deletes and inserts, the other deletes nothing and then loses the unique
    # index to the first, and `fetch/3` hands it the winner's row.
    discard_expired(attrs)

    # The insert IS in a transaction of its own, and that is a different
    # decision from the one above. A losing insert is a unique-violation
    # STATEMENT error, and Postgres aborts the enclosing transaction on one —
    # so under a scoped request transaction (see `CourierWeb.Plugs.Idempotency`)
    # a returned `{:error, :taken}` would poison the request's own commit and
    # turn every retry into a 503. `Repo.rollback/1` unwinds only to this
    # transaction's boundary — a savepoint under a scoped request, a real
    # transaction otherwise — and the reason survives it, which is what the
    # paragraph above refused to give up: the outer `case` re-maps it, so
    # `{:error, :taken}` still means taken and never `{:error, :rollback}`.
    case Repo.transaction(fn ->
      case %IdempotencyKey{}
           |> IdempotencyKey.changeset(Map.put_new(attrs, :expires_at, expires_at()))
           |> Repo.insert() do
        {:ok, key} -> {:ok, key}
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(refusal(changeset))
      end
    end) do
      # The inner transaction adds its own `{:ok, …}` level — see the probe in
      # `test/courier/shape_probe_test.exs` — so success arrives doubly
      # wrapped and the rollback reasons singly.
      {:ok, {:ok, key}} -> {:ok, key}
      {:error, :taken} -> {:error, :taken}
      {:error, {:error, changeset}} -> {:error, {:error, changeset}}
    end
  end

  # The one refusal that means "someone else has this key" rather than "the claim
  # was malformed". It is matched on the index by name, not merely on
  # `constraint: :unique`, so a future unique index on this table cannot silently
  # turn into a 409 a client is told to retry.
  #
  # The name arrives as a **string**, from the adapter, even though the
  # `unique_constraint/3` it was declared with was given an atom — compared as
  # strings so the two spellings of the same thing cannot disagree.
  defp refusal(changeset) do
    taken? =
      Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
        Keyword.get(opts, :constraint) == :unique and
          to_string(Keyword.get(opts, :constraint_name)) == @claim_index
      end)

    if taken?, do: :taken, else: {:error, changeset}
  end

  @doc """
  The unexpired claim on this triple, or `nil`.

  "Unexpired" is decided here rather than by a database constraint, because a
  Postgres partial index cannot compare against `now()` and a stale `in_flight`
  row must still be visible to the request that finds it — it is the thing telling
  the caller their first attempt is still running.
  """
  @spec fetch(Ecto.UUID.t(), String.t(), String.t()) :: IdempotencyKey.t() | nil
  def fetch(account_id, endpoint, key) do
    now = DateTime.utc_now()

    IdempotencyKey
    |> where([k], k.account_id == ^account_id and k.endpoint == ^endpoint)
    |> where([k], k.idempotency_key == ^key and k.expires_at > ^now)
    |> Repo.one()
  end

  @doc """
  Stores the response on a claim the caller owns.
  """
  @spec complete(Ecto.UUID.t(), pos_integer(), binary(), String.t()) ::
          {:ok, IdempotencyKey.t()} | {:error, Ecto.Changeset.t()}
  def complete(id, status, body, content_type) do
    IdempotencyKey
    |> Repo.get!(id)
    |> IdempotencyKey.completion(status, body, content_type)
    |> Repo.update()
  end

  @doc """
  Drops a claim whose request did not succeed, so the key is free to be used
  again immediately rather than at the end of its retention window.
  """
  @spec release(Ecto.UUID.t()) :: {integer(), nil}
  def release(id) do
    Repo.delete_all(where(IdempotencyKey, [k], k.id == ^id))
  end

  @doc """
  Deletes every claim past its retention window.

  Exposed for an operator and for a test; nothing calls it on a timer, because
  `claim/1` already discards the expired rows for every triple anybody presents.
  """
  @spec purge_expired() :: {integer(), nil}
  def purge_expired, do: Repo.delete_all(expired_claims())

  # The `where([k], ...)` form and not `where(queryable, expires_at: ^now)`, and
  # the difference is not stylistic. **The keyword form does not apply the
  # schema's field type to an interpolated value**: a `DateTime` handed to it
  # arrives at the database uncast, so the comparison against a
  # `timestamp without time zone` column silently matches nothing.
  #
  # Measured, because a green test would not have caught it — the first version of
  # this function used the keyword form and returned `{0, nil}` against a table
  # that plainly held an expired row:
  #
  #     raw SQL   SELECT count(*) … WHERE expires_at < $1   -> 1
  #     keyword   where(IdempotencyKey, expires_at: ^now)   -> []
  #     macro     where([k], k.expires_at < ^now)           -> the row
  #
  # The macro form knows the field and casts the value as that field's type, so
  # every query in this module uses it.
  defp expired_claims do
    now = less_than_now()
    where(IdempotencyKey, [k], k.expires_at < ^now)
  end

  @doc """
  Whether a stored `Idempotency-Key` is the shape core asks for: a uuid, chosen
  by the client.

  Courier-12 measured that a non-uuid key and a 5000-character key were both
  accepted without complaint. Accepting them is not a harmless permissiveness —
  an unbounded key is written to a unique index, and a client that sends a
  megabyte of key is a client that can make every write it makes expensive.
  """
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key) when is_binary(key), do: match?({:ok, _}, Ecto.UUID.cast(key))
  def valid_key?(_key), do: false

  # Both halves of the expiry decision live here so `claim/1` and `purge_expired/0`
  # cannot be built against different clocks.
  defp discard_expired(%{account_id: account_id, endpoint: endpoint, idempotency_key: key}) do
    IdempotencyKey
    |> where([k], k.account_id == ^account_id and k.endpoint == ^endpoint)
    |> where([k], k.idempotency_key == ^key and k.expires_at < ^less_than_now())
    |> Repo.delete_all()
  end

  defp expires_at, do: DateTime.add(DateTime.utc_now(), @retention_hours * 3600, :second)

  defp less_than_now, do: DateTime.utc_now()
end
