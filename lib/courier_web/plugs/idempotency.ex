defmodule CourierWeb.Plugs.Idempotency do
  @moduledoc """
  Accepts `Idempotency-Key` on a mutating `POST` and makes a retry free.

  Core's `docs/openapi-conventions.md` §Idempotency is the specification, in
  five sentences, and this plug is where each one lives:

  | core | here |
  | ---- | ---- |
  | "`Idempotency-Key: <uuid>`, chosen by the client" | `present/1` — absent is normal, a non-uuid is a 422 |
  | "Scope: the `(endpoint, principal, key)` triple" | the claim is keyed on `conn.assigns.current_account` and `conn.request_path` |
  | "Retention: 24 hours, stored with the response" | `Courier.Idempotency.claim/1` |
  | "Replay with the same key **and** the same request body returns the original response and `Idempotency-Replayed: true`" | `replay/2` |
  | "Replay with the same key but a different body returns 409 `idempotency_key_reused`" | `reused/1` |
  | "Requests without the key are processed normally" | the first clause of `call/2` |

  ## The fourth case, which core does not describe

  Two requests with one key arriving **at the same time** is not a retry — the
  first has not answered yet, so there is no response to give back. core's five
  sentences do not reach it, and the choice here is deliberate:

  It is a **409 `conflict`**, not a replay and not a third code. It is not
  `idempotency_key_reused`, which would say the key was used twice with different
  bodies when in fact the bodies are identical. It is `conflict` because that is
  what it is: this request conflicts with the state of the resource, and core
  already reserves the code for 409. The `detail` says which case it is, so a
  client that hits it knows to retry the same key shortly rather than to change
  anything.

  ## The hash is over the decoded body

  `request_hash/1` hashes the **parsed** params, not the bytes on the wire. Two
  bodies that mean the same thing are therefore the same request, and a client
  that reformats its JSON between a call and its retry gets a replay rather than
  a conflict it did nothing to cause. The canonical form sorts map keys, because
  a hash that depended on the order a JSON parser happened to produce would make
  "the same body" mean something an implementation detail decides.

  The raw body is not available here and could not be: `CourierWeb.Plugs.ParseBody`
  is an **endpoint** plug, so it has already read and parsed the body by the time
  any router pipeline runs.

  ## Nothing here logs the key or the body

  A stored `response_body` on `POST /v1/webhook_endpoints` is the 201 carrying the
  `whsec_` signing secret. A log line carrying it would be a credential in a log,
  so the failure path below reports the row's own uuid and the status and nothing
  else. The key itself is client-chosen and not a secret, but it is not logged
  either — a store failure is diagnosable from a row id.
  """

  import Plug.Conn

  require Logger

  alias Courier.Idempotency
  alias Courier.IdempotencyKey
  alias Courier.Repo
  alias Courier.Tenancy
  alias CourierWeb.Problem

  @key_header "idempotency-key"
  @replayed_header "idempotency-replayed"

  @doc false
  def key_header, do: @key_header

  @doc false
  def replayed_header, do: @replayed_header

  @doc """
  The key the client sent, or `nil`.

  A header sent more than once is a request nobody can interpret — there is no
  rule that says which of two values wins — so it is treated as absent rather than
  as the first one, which would make the answer depend on a proxy's mood.
  """
  @spec present(Plug.Conn.t()) :: String.t() | nil
  def present(conn) do
    case get_req_header(conn, @key_header) do
      [key] when is_binary(key) -> key
      _other -> nil
    end
  end

  @doc false
  def init(opts), do: opts

  def call(conn, _opts) do
    case present(conn) do
      # core: "Requests without the key are processed normally." No row, no
      # lookup, no response the client did not ask for.
      nil -> conn
      key -> keyed(conn, key)
    end
  end

  defp keyed(conn, key) do
    if Idempotency.valid_key?(key) do
      guarded(conn, key)
    else
      refused(conn)
    end
  end

  # The claim is taken *here*, before the controller, and the answer is stored in
  # `before_send` — the only ordering in which a second request with this key can
  # find a row rather than run the action again.
  #
  # Each database call below runs inside its own `Tenancy.with_account/3`: the
  # claim, the lookup, and the store each open the transaction that carries the
  # caller's account to the row-level-security policies on `idempotency_keys`.
  # A plug cannot hold one transaction open across the plugs and the controller
  # that run after it returns — `CourierWeb.Plugs.TenantIdentity` tried exactly
  # that, and every authenticated request's protected-table access died on the
  # first write with a 42501 — so the scope lives where a transaction can
  # legitimately wrap the work: around each unit of it. `conn.assigns.
  # current_account` is the tenancy key in every case, put there by
  # `CourierWeb.Plugs.Principal`, which runs before this plug and halts a 401
  # for a caller that has none.
  defp guarded(conn, key) do
    account_id = conn.assigns.current_account
    endpoint = conn.request_path
    hash = request_hash(conn)

    case scoped(conn, fn ->
           Idempotency.claim(%{
             account_id: account_id,
             endpoint: endpoint,
             idempotency_key: key,
             request_hash: hash
           })
         end) do
      {:ok, claim} -> register(conn, claim)
      {:error, :taken} -> decided(conn, account_id, endpoint, key, hash)
      {:error, {:error, changeset}} -> changeset_error(conn, changeset)
      :unavailable -> unavailable(conn)
    end
  end

  # `{:error, _}` from `with_account/3` — a `Repo.rollback` that escaped the
  # function — is unreachable by construction: `Courier.Idempotency` never calls
  # `Repo.rollback`. It is handled rather than matched away because a security
  # control that raises `MatchError` on a shape it cannot explain is one whose
  # failure nobody has diagnosed, and the answer is the same shape the rest of
  # courier uses for "a dependency did not work": a 503 the caller may retry.
  #
  # The `{:ok, …}` wrap is load-bearing, and `Courier.Idempotency`'s moduledoc
  # says why: `Repo.transaction/1` rolls the transaction back when its function
  # *returns* `{:error, _}`, so an unwrapped claim would arrive as
  # `{:error, :taken}` — indistinguishable from a rollback — and every retry
  # would be a 503. Wrapping the value commits it instead, and only a genuine
  # rollback still answers `:unavailable`.
  defp scoped(conn, fun) do
    case Tenancy.with_account(Repo, conn.assigns.current_account, fn -> {:ok, fun.()} end) do
      {:ok, {:ok, value}} -> value
      {:error, _reason} -> :unavailable
    end
  end

  defp unavailable(conn) do
    conn
    |> Problem.send(
      503,
      :unavailable,
      "courier could not scope this request to an account, so it is not serving it."
    )
    |> halt()
  end

  defp decided(conn, account_id, endpoint, key, hash) do
    case scoped(conn, fn -> Idempotency.fetch(account_id, endpoint, key) end) do
      %IdempotencyKey{state: :completed} = stored ->
        if stored.request_hash == hash, do: replay(conn, stored), else: reused(conn)

      %IdempotencyKey{state: :in_flight} ->
        in_flight(conn)

      :unavailable ->
        unavailable(conn)

      nil ->
        # Not reachable, and the reason is worth writing down rather than
        # handling as though it were. `claim/1` deletes this triple's expired rows
        # in the same transaction as the insert that reported `:taken`, so the row
        # that blocked the insert was unexpired microseconds ago and cannot have
        # become expired since. If it ever does, refusing is the safe direction: a
        # caller that gets a 409 retries, and one that is let through would run a
        # mutation nobody can deduplicate.
        Logger.error(
          "idempotency claim lost with no row to read: row=#{Ecto.UUID.generate()} " <>
            "endpoint=#{endpoint} status=409"
        )

        in_flight(conn)
    end
  end

  defp register(conn, claim) do
    register_before_send(conn, &store(&1, claim))
  end

  defp store(conn, claim) do
    # The store runs in `before_send`, after the controller's own scoped
    # transaction has committed, so it opens its own — same account, new
    # transaction. The result is deliberately ignored: the response is already
    # built, and nothing here may turn it into a 500 (see `complete/3`'s
    # rescue, which is the same rule one layer down).
    scoped(conn, fn ->
      case body(conn) do
        nil -> Idempotency.release(claim.id)
        stored -> complete(claim, conn, stored)
      end
    end)

    conn
  end

  defp complete(claim, conn, stored) do
    case Idempotency.complete(claim.id, conn.status, stored, content_type(conn)) do
      {:ok, _stored} ->
        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        report(claim, conn.status, "refused the stored response", changeset)
    end
  rescue
    error ->
      # A failure here must not turn a 201 into a 500: the mutation already
      # happened and the caller has already been told it did. The worst case of
      # not storing is a retry that re-runs, which is the behaviour courier had
      # before this plug and is not a failure of the request in front of us.
      report(claim, conn.status, "raised while storing the response", error)
  end

  defp report(claim, status, what, detail) do
    Logger.error(
      "idempotency #{what}: row=#{claim.id} status=#{status} reason=#{inspect(detail)}"
    )
  end

  defp replay(conn, stored) do
    conn
    |> put_resp_content_type(stored.response_content_type)
    |> put_resp_header(@replayed_header, "true")
    |> send_resp(stored.response_status, stored.response_body)
    |> halt()
  end

  # Same key, different body. The message is specific about the two things that
  # differ, because "conflict" on its own tells a client nothing it can act on.
  defp reused(conn) do
    Problem.send(
      conn,
      409,
      :idempotency_key_reused,
      "That Idempotency-Key was already used for a different request body on this " <>
        "endpoint. Reuse the original body to get the original response, or send a " <>
        "new key."
    )
    |> halt()
  end

  # Same key, same body, still running. See the moduledoc: core does not describe
  # this case, and this is the code it is answered with.
  defp in_flight(conn) do
    Problem.send(
      conn,
      409,
      :conflict,
      "That Idempotency-Key is still being processed. Retry the same request with " <>
        "the same key once it has answered."
    )
    |> halt()
  end

  defp refused(conn) do
    conn
    |> Problem.send(
      422,
      :validation_failed,
      "The Idempotency-Key is not valid.",
      [
        %{
          "field" => "Idempotency-Key",
          "code" => "invalid_format",
          "detail" => "It must be a uuid, chosen by the client."
        }
      ]
    )
    |> halt()
  end

  defp changeset_error(conn, changeset) do
    Problem.send(
      conn,
      422,
      :validation_failed,
      "The Idempotency-Key could not be recorded.",
      Enum.map(changeset.errors, fn {field, {_message, opts}} ->
        %{"field" => to_string(field), "code" => Keyword.get(opts, :code, "invalid_format")}
      end)
    )
    |> halt()
  end

  # `2xx`, by the status the controller actually produced.
  defp successful?(status), do: status in 200..299

  # **The body is iodata, not a binary.** `Phoenix.Controller.json/2` encodes to
  # iodata and hands that straight to `send_resp`, and `Plug.Conn` stores whatever
  # it is given — so `conn.resp_body` inside a `before_send` callback is a deep
  # list of binaries and byte lists, and `is_binary/1` is false for it.
  #
  # The first draft of this plug required a binary and so released every claim,
  # which is the one failure mode with no error message: nothing raised, the
  # request answered 201, and the retry simply created a second endpoint. It is
  # written down here because the symptom points nowhere near the cause.
  #
  # `nil` means there is no body to store, and the claim is released instead: a
  # 204 has already removed the resource, and a response with nothing in it is not
  # one a retry should be answered with.
  defp body(conn) do
    if successful?(conn.status), do: flatten(conn.resp_body)
  end

  defp flatten(nil), do: nil
  defp flatten(body) when is_binary(body), do: body
  defp flatten(iodata), do: IO.iodata_to_binary(iodata)

  defp content_type(conn) do
    case get_resp_header(conn, "content-type") do
      [content_type | _rest] -> content_type
      [] -> "application/json"
    end
  end

  @doc """
  The hash of a request's method, path and **decoded** body.

  Public because it is the thing worth asserting on: a test that two bodies
  which differ only in key order hash the same is a test about the claim, not
  about this function's plumbing.
  """
  @spec request_hash(Plug.Conn.t()) :: String.t()
  def request_hash(conn) do
    sha = [conn.method, "\n", conn.request_path, "\n", canonical(conn.body_params)]

    :sha256 |> :crypto.hash(sha) |> Base.encode16(case: :lower)
  end

  # Sorted, so the encoding of a given request is a property of the request
  # rather than of the order a JSON object happened to arrive in.
  #
  # An empty map and no body at all are the same request, and they hash the same
  # way: a JSON body of `{}` carries no fields, so treating it as different from
  # sending nothing would make `POST /:id/test` — which has no body — conflict
  # with itself depending on whether a client's HTTP library bothered to send an
  # empty object.
  defp canonical(%Plug.Conn.Unfetched{}), do: ""
  defp canonical(params) when is_map(params) and map_size(params) == 0, do: ""
  defp canonical(%{__struct__: _} = struct), do: inspect(struct)

  defp canonical(params) when is_map(params) do
    inner =
      params
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, value} -> "#{key}:#{canonical(value)}" end)

    "{" <> inner <> "}"
  end

  defp canonical(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"

  defp canonical(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: inspect(value)
end
