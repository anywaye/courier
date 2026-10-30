defmodule Courier.Idempotency do
  @moduledoc """
  The context over `idempotency_keys`: claiming a key, and either storing the
  answer or giving it back.

  Core's `docs/openapi-conventions.md` §Idempotency is the specification. This
  module implements the storage half of it; `CourierWeb.Plugs.Idempotency` is the
  half that reads a header and answers a request, and the two are split so the
  arithmetic can be tested without a plug pipeline and the wiring can be tested
  without a database.


  A key that is only recorded *after* the action cannot prevent anything. Two
  requests with one key would both run, both mutate, and both try to store — and
  the second store would either overwrite the first or be rejected, after the
  damage. So `claim/1` is called before the controller and `complete/4` after it,
  and the row exists in between in the `in_flight` state, which is what a second
  request with the same key finds.


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


  core says 24 hours. Nothing sweeps the table on a timer — a second supervision
  tree for a table this size is a service that can be down — so `claim/1` deletes
  the expired rows for the triple it is about to claim, immediately before the
  insert. A key the caller has not used for a day behaves as though it had never
  been used, which is what "retention: 24 hours" means, and the sweep only ever
  runs on a key somebody is actually presenting.


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
    discard_expired(attrs)

    %IdempotencyKey{}
    |> IdempotencyKey.changeset(Map.put_new(attrs, :expires_at, expires_at()))
    |> Repo.insert(mode: :savepoint)
    |> case do
      {:ok, key} -> {:ok, key}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, refusal(changeset)}
    end
  end

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

  defp discard_expired(%{account_id: account_id, endpoint: endpoint, idempotency_key: key}) do
    IdempotencyKey
    |> where([k], k.account_id == ^account_id and k.endpoint == ^endpoint)
    |> where([k], k.idempotency_key == ^key and k.expires_at < ^less_than_now())
    |> Repo.delete_all()
  end

  defp expires_at, do: DateTime.add(DateTime.utc_now(), @retention_hours * 3600, :second)

  defp less_than_now, do: DateTime.utc_now()
end
