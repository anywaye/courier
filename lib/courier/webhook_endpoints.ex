defmodule Courier.WebhookEndpoints do
  @moduledoc """
  The context over `webhook_endpoints`: registering an endpoint, changing it,
  removing it, and the two states the delivery pipeline asks about.

  ## The URL is checked here, not in the changeset

  `create/1` and `update/2` run `Courier.Webhooks.UrlGuard` before touching the
  database. That ordering is the whole security property: an SSRF target is
  refused at the moment an account tries to register it, so the row that exists
  is a row courier is willing to sign for. A design that stored the URL and
  checked it at send time would leave a table full of `169.254.169.254` for
  whatever found it first.

  The guard needs a resolver, so it is configuration rather than a hard-coded
  call — `config :courier, :dns_resolver`. That is also what makes the SSRF tests
  possible without a network.

  ## The secret

  Generated on create, returned once, sealed at rest. `create/1` answers
  `{:ok, endpoint, secret}` — the plaintext is handed back here and nowhere else,
  because the API returns it exactly once and after that it exists only as
  ciphertext. A customer who loses it rotates the endpoint; courier does not keep
  a copy it could mail out again.
  """

  import Ecto.Query, warn: false

  alias Courier.Repo
  alias Courier.SecretBox
  alias Courier.WebhookEndpoint
  alias Courier.Webhooks.Signature
  alias Courier.Webhooks.UrlGuard

  @type result :: {:ok, WebhookEndpoint.t()} | {:error, Ecto.Changeset.t()}

  @doc """
  Registers an endpoint for `attrs[:account_id]`.

  Returns `{:ok, endpoint, secret}` where `secret` is the `whsec_` plaintext the
  customer pastes into their verifier. It is returned once, here, and never
  again — there is no `GET` that can produce it, because a `GET` that could would
  be a credential endpoint.

  Errors are two kinds and the difference matters to the caller. A
  `{:error, changeset}` is a typo — a missing field, a relative url, a duplicate.
  A `{:error, reason}` from the guard is a *refusal*: the url is a well-formed
  url courier will not send to, and the reason says which class it was, so the
  API can tell the customer their host resolves to a private address rather than
  that they typed it wrong.
  """
  @spec create(map()) ::
          {:ok, WebhookEndpoint.t(), Signature.secret()} | {:error, Ecto.Changeset.t() | atom()}
  def create(attrs) do
    with {:ok, url} <- fetch_url(attrs) do
      changeset = WebhookEndpoint.changeset(%WebhookEndpoint{}, attrs)

      # The shape is validated before the guard so a malformed url costs no DNS
      # lookup, and a well-formed-looking one cannot be waved past the shape by
      # resolving before anyone noticed it was nonsense.
      case valid?(changeset) do
        false -> {:error, changeset}
        true -> create_validated(changeset, url)
      end
    end
  end

  defp create_validated(changeset, url) do
    with :ok <- check_url(url) do
      secret = Signature.generate_secret()

      # The insert runs in a transaction of its own — a savepoint under a scoped
      # request transaction, a real one otherwise. A refused insert (a duplicate
      # url) is a STATEMENT error, and Postgres aborts the enclosing transaction
      # on one: returning the changeset would poison the request's own commit and
      # turn a 422 into a 500. `Repo.rollback/1` unwinds only to this boundary,
      # so the caller still gets the changeset it validates.
      case Repo.transaction(fn ->
        case changeset |> put_secret(secret) |> Repo.insert() do
          {:ok, endpoint} -> {:ok, {endpoint, secret}}
          {:error, %Ecto.Changeset{} = refused} -> Repo.rollback(refused)
        end
      end) do
        # The inner transaction adds its own `{:ok, …}` level — see the probe
        # in `test/courier/shape_probe_test.exs`.
        {:ok, {:ok, {endpoint, secret}}} -> {:ok, endpoint, secret}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      end
    end
  end

  defp valid?(changeset), do: changeset.valid?

  @doc """
  The endpoint `id` in `account_id`, or `nil`.

  `nil` rather than an error, because the two questions are the same question:
  "is this endpoint yours?" — and for an endpoint in another account the honest
  answer is no, without a distinction that would tell a caller the row exists.
  """
  @spec get(String.t() | Ecto.UUID.t(), Ecto.UUID.t()) :: WebhookEndpoint.t() | nil
  def get(id, account_id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(WebhookEndpoint, id: id, account_id: account_id)
      :error -> nil
    end
  end

  @doc """
  Every endpoint in `account_id`, oldest first.

  Disabled ones included. Disabling is not deleting: the row carries the failure
  count and the reason delivery stopped, and a support conversation about "my
  webhooks stopped last Tuesday" needs that row to still be there.
  """
  @spec list(Ecto.UUID.t()) :: [WebhookEndpoint.t()]
  def list(account_id) do
    WebhookEndpoint
    |> where([endpoint], endpoint.account_id == ^account_id)
    |> order_by([endpoint], asc: endpoint.inserted_at, asc: endpoint.id)
    |> Repo.all()
  end

  @doc """
  The enabled endpoints of `account_id` — the fan-out list.

  This is the query the delivery pipeline runs, and it is why the index on
  `(account_id, inserted_at) WHERE status = 'enabled'` exists.
  """
  @spec enabled(Ecto.UUID.t()) :: [WebhookEndpoint.t()]
  def enabled(account_id) do
    WebhookEndpoint
    |> where([endpoint], endpoint.account_id == ^account_id and endpoint.status == :enabled)
    |> order_by([endpoint], asc: endpoint.inserted_at, asc: endpoint.id)
    |> Repo.all()
  end

  # Core's openapi-conventions: "Cursor-based everywhere… `limit` defaults to 25
  # and is capped at 100. `cursor` is an opaque base64url string; clients must not
  # parse it, and its encoding may change without notice."
  @default_limit 25
  @max_limit 100

  @doc false
  def default_limit, do: @default_limit
  @doc false
  def max_limit, do: @max_limit

  @doc """
  One page of `account_id`'s endpoints, oldest first.

  Returns `{:ok, %{data: endpoints, page: page}}`, or `{:error, :invalid_cursor}`
  for a cursor courier did not issue. The cursor is the base64url of the last id
  on the previous page and is compared as a *lower bound* against
  `(inserted_at, id)`, so a page boundary is stable while new endpoints are being
  created — an offset would skip or repeat rows as the table grows under it.
  """
  @spec page(Ecto.UUID.t(), pos_integer() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, :invalid_cursor}
  def page(account_id, limit, cursor) do
    with {:ok, limit} <- validate_limit(limit),
         {:ok, after_row} <- decode_cursor(cursor) do
      query =
        WebhookEndpoint
        |> where([endpoint], endpoint.account_id == ^account_id)
        |> order_by([endpoint], asc: endpoint.inserted_at, asc: endpoint.id)
        |> limit(^Kernel.+(limit, 1))

      # `limit + 1` rows is how `has_more` is answered without a second query: ask
      # for one more than was asked for, and if it arrives there is another page.
      rows = query |> after_row(after_row) |> Repo.all()
      has_more? = length(rows) > limit
      page = Enum.take(rows, limit)

      {:ok,
       %{
         data: page,
         page: %{
           next_cursor: if(has_more?, do: encode_cursor(List.last(page)), else: nil),
           has_more: has_more?
         }
       }}
    end
  end

  defp after_row(query, nil), do: query

  defp after_row(query, {inserted_at, id}) do
    where(
      query,
      [endpoint],
      {endpoint.inserted_at, endpoint.id} > {^inserted_at, ^id}
    )
  end

  defp validate_limit(nil), do: {:ok, @default_limit}

  defp validate_limit(limit) when is_integer(limit) do
    {:ok, min(limit, @max_limit)}
  end

  defp validate_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed > 0 -> {:ok, min(parsed, @max_limit)}
      _not_a_positive_integer -> {:error, :invalid_limit}
    end
  end

  defp validate_limit(_limit), do: {:error, :invalid_limit}

  # Opaque to the client, per core: the encoding is courier's and may change. What
  # it has to carry is the row's position, because the comparison is a lower bound
  # on `(inserted_at, id)` rather than an offset.
  #
  # The timestamp goes in as ISO 8601 rather than as a `DateTime` struct, because
  # `Jason.encode!/1` on a struct writes its `Inspect` representation — which is not
  # what `DateTime.from_iso8601/1` reads back. A cursor that does not survive its
  # own round trip is a cursor that 422s on the second page of every list.
  defp encode_cursor(%WebhookEndpoint{} = endpoint) do
    [DateTime.to_iso8601(endpoint.inserted_at), endpoint.id]
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, [iso8601, id]} <- Jason.decode(decoded),
         {:ok, inserted_at, 0} <- DateTime.from_iso8601(iso8601),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {inserted_at, id}}
    else
      _not_a_cursor_courier_issued -> {:error, :invalid_cursor}
    end
  end

  @doc """
  Changes an endpoint.

  Re-runs the URL guard: a `PATCH` that sets a new url is a new destination, and
  a new destination gets the same check the first one did. The shape is validated
  before the guard, for the same reason as in `create/1`.
  """
  @spec update(WebhookEndpoint.t(), map()) :: result() | {:error, atom()}
  def update(%WebhookEndpoint{} = endpoint, attrs) do
    changeset = WebhookEndpoint.update_changeset(endpoint, attrs)

    if valid?(changeset) do
      with :ok <- check_url(Ecto.Changeset.get_field(changeset, :url)) do
        # A savepoint under a scoped request transaction, for the same reason
        # as `create_validated/2`: a refused update must not poison the
        # request's own commit.
        #
        # The inner transaction adds its own `{:ok, …}` level — see the probe
        # in `test/courier/shape_probe_test.exs` — so success arrives doubly
        # wrapped and is unwrapped here, keeping this function's tuples what
        # they were.
        (case Repo.transaction(fn ->
           case changeset |> Repo.update() do
             {:ok, updated} -> {:ok, updated}
             {:error, %Ecto.Changeset{} = refused} -> Repo.rollback(refused)
           end
         end) do
           {:ok, {:ok, updated}} -> {:ok, updated}
           {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
         end)
        # A customer re-enabling an endpoint clears courier's failure count and
        # reason with it: they looked at the endpoint courier gave up on and said
        # to try again, and leaving "5 consecutive failures, last: connection
        # refused" on a row that is now enabled is courier second-guessing them.
        |> clear_reason_when_reenabled(endpoint)
      end
    else
      {:error, changeset}
    end
  end

  defp clear_reason_when_reenabled({:ok, updated}, endpoint) do
    # The count goes with the reason. A customer who re-enables an endpoint that
    # courier tripped has been told "5 consecutive failures" and has decided to
    # try again; carrying the count forward means the circuit re-opens on their
    # very next failure, before the new attempt has had a chance to succeed, which
    # is not what "try again" can reasonably mean to them.
    if endpoint.status == :disabled and updated.status == :enabled and
         is_binary(updated.disabled_reason) do
      updated
      |> Ecto.Changeset.change(disabled_reason: nil, consecutive_failures: 0)
      |> Repo.update()
    else
      {:ok, updated}
    end
  end

  defp clear_reason_when_reenabled({:error, _changeset} = error, _endpoint), do: error

  @doc """
  Removes an endpoint.

  `{:error, :not_found}` for a row that is already gone, so a double `DELETE`
  is not reported as a success it did not have.
  """
  @spec delete(WebhookEndpoint.t()) :: result() | {:error, :not_found}
  def delete(%WebhookEndpoint{} = endpoint) do
    case Repo.delete(endpoint) do
      {:ok, _deleted} -> {:ok, endpoint}
      {:error, _changeset} -> {:error, :not_found}
    end
  end

  @doc """
  Records a failure against an endpoint and disables it if the circuit is open.

  `threshold` is how many consecutive failures trip the circuit; `reason` is the
  last thing that went wrong, kept because "delivery stopped" with no reason is
  not an answer a customer can act on.

  A single failure never disables. The counter is what the threshold is compared
  against, so a consumer that is briefly down does not lose its endpoint.
  """
  @spec trip(WebhookEndpoint.t(), pos_integer(), String.t()) :: result()
  def trip(%WebhookEndpoint{} = endpoint, threshold, reason) do
    # The count is read from the row, not from the struct that was passed in. A
    # delivery worker holds one endpoint struct across several deliveries, and
    # incrementing a stale copy means every one of them writes the same number —
    # so the counter never reaches the threshold and the circuit never opens. That
    # is the shape of bug this is here to prevent, not a theoretical one.
    #
    # `Repo.reload/1` is not enough on its own: it answers the struct it was given
    # when the struct is already loaded, which is the case this is guarding. So
    # the row is fetched by id instead.
    case fetch(endpoint.id) do
      %WebhookEndpoint{} = current -> record_failure(current, threshold, reason)
      nil -> {:error, :not_found}
    end
  end

  defp fetch(id), do: Repo.get(WebhookEndpoint, id)

  defp record_failure(%WebhookEndpoint{} = endpoint, threshold, reason) do
    failures = endpoint.consecutive_failures + 1

    if failures >= threshold do
      endpoint
      |> Ecto.Changeset.change(
        status: :disabled,
        consecutive_failures: failures,
        disabled_reason: "#{failures} consecutive failures, last: #{reason}"
      )
      |> Repo.update()
    else
      endpoint
      |> Ecto.Changeset.change(consecutive_failures: failures)
      |> Repo.update()
    end
  end

  @doc """
  Disables an endpoint and records why.

  For the cases courier decides on its own, outside the consecutive-failure
  count: a receiver answering `410 Gone`, which the spec §Delivery success and
  failure says should disable the endpoint outright. The count is not touched —
  nothing is known about how many failures there were — but the reason is
  written, because "delivery stopped" with nothing to explain it is not an answer
  a customer can act on.
  """
  @spec disable(WebhookEndpoint.t(), String.t()) :: result()
  def disable(%WebhookEndpoint{} = endpoint, reason) do
    endpoint
    |> Ecto.Changeset.change(status: :disabled, disabled_reason: reason)
    |> Repo.update()
  end

  @doc """
  Records a successful delivery: the failure count returns to zero.

  An endpoint courier disabled for its own reasons is re-enabled, because a
  circuit that never closes is not a circuit. An endpoint the *customer*
  disabled stays disabled — the counter is cleared, the decision is not undone,
  because a customer who turned an endpoint off does not expect one lucky
  delivery to turn it back on.
  """
  @spec record_success(WebhookEndpoint.t()) :: result()
  def record_success(%WebhookEndpoint{} = endpoint) do
    endpoint
    |> Ecto.Changeset.change(consecutive_failures: 0)
    |> maybe_reenable()
    |> Repo.update()
  end

  @doc """
  The plaintext signing secret for an endpoint.

  Opens the sealed column. This is the only read path, and the only reason
  `Courier.Webhooks.Signature` is ever handed a `whsec_` string inside courier.
  """
  @spec secret(WebhookEndpoint.t()) :: {:ok, Signature.secret()} | {:error, :invalid_ciphertext}
  def secret(%WebhookEndpoint{secret: sealed}), do: SecretBox.open(sealed)

  @doc """
  The plaintext secret, or `nil` if the row cannot be opened.

  For the one call site that has no way to handle an unreadable row — building a
  `201` response — where `secret/1`'s error tuple would only be pattern-matched
  away. Nothing on the delivery path uses this: a delivery that could not open its
  key has to fail loudly, and `secret/1` is what makes that failure a value
  rather than a nil.
  """
  @spec plaintext_secret(WebhookEndpoint.t()) :: Signature.secret() | nil
  def plaintext_secret(%WebhookEndpoint{} = endpoint) do
    case secret(endpoint) do
      {:ok, secret} -> secret
      {:error, :invalid_ciphertext} -> nil
    end
  end

  # Re-enables only when courier is the one that disabled it, which it records by
  # writing a `disabled_reason`. A customer-disabled endpoint has none, because
  # courier did not write one — and a single lucky delivery must not undo a
  # decision the customer made about their own endpoint.
  defp maybe_reenable(changeset) do
    if changeset.data.status == :disabled and is_binary(changeset.data.disabled_reason) do
      Ecto.Changeset.change(changeset, status: :enabled, disabled_reason: nil)
    else
      changeset
    end
  end

  defp put_secret(changeset, secret) do
    Ecto.Changeset.put_change(changeset, :secret, SecretBox.seal(secret))
  end

  # `nil` is allowed through: `update/2` falls back to the row's own url, and a
  # changeset with no url at all fails on its own `validate_required/2`.
  defp fetch_url(attrs) do
    case attrs[:url] || attrs["url"] do
      url when is_binary(url) -> {:ok, url}
      _absent_or_not_a_string -> {:error, :invalid_url}
    end
  end

  defp check_url(nil), do: :ok

  defp check_url(url) when is_binary(url) do
    case UrlGuard.validate(url, resolver()) do
      {:ok, _target} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_url(_other), do: {:error, :invalid_url}

  defp resolver, do: Application.get_env(:courier, :dns_resolver, Courier.Webhooks.Dns.System)
end
