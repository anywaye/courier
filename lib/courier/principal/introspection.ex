defmodule Courier.Principal.Introspection do
  @moduledoc """
  courier's door, and the key it turns.

  `config :courier, :principal` names this module when courier is not in test, and
  it answers the one question `CourierWeb.Plugs.Principal` asks: who is calling.


  **`COURIER_IDENTITY_TOKEN`, a scoped API token courier holds as its own
  credential**, presented as `Authorization: Bearer` on identity's
  `POST /v1/introspections`; the caller's presented token goes in the **body**.

  It is a service credential and it is treated as one:

    * **It comes from the environment, at boot, and nowhere else.** Not argv —
      `kamal`'s `env.secret` is a secret read from the environment, and anything
      on a command line is in `ps` output and in the shell history of whoever
      deployed. Not a config file: a committed value is a value in git.
    * **It is never logged, never echoed, and never part of a reason.** Every
      refusal below is a symbol; `test/courier/principal/introspection_test.exs`
      captures real log output and asserts the token is ABSENT, which is the
      assertion worth more than "it logged something" — a boundary that deletes
      everything passes that.
    * **Rotation is identity's, not courier's.** Mint a new key
      (`POST /v1/accounts/{account_id}/api-keys`), redeploy with the new value,
      revoke the old one. There is no cache to invalidate, which is the second
      half of why there is no cache (below).
    * **It must be the same key identity presents as its `COURIER_TOKEN`.**
      This is the one provisioning requirement of the seam, and it cannot be
      inferred from courier's source. identity's introspection endpoint lets a
      token caller introspect **only itself** — "an api key may only introspect
      itself" (`identity/internal/httpapi/apikeys.go`) — so the seam works when
      ONE key is held by both services: identity presents it outbound on its
      call to `POST /v1/messages`, and courier presents it to introspect the
      inbound request. The rule then reads exactly right: courier is asking "is
      this bearer a live key, and is it the one I hold?", and only identity's
      own key answers yes. **Two distinct keys produce identity's 403 and
      courier's 503**, and the symptom is indistinguishable from a network
      fault. Tightening identity's rule is identity's decision (packet m65),
      not courier's; courier reports the 403 as a 503 and says so here.


  RFC 7662 §2.1 permits a protected resource to introspect using the token
  itself, and identity implements exactly that affordance — "a token may
  introspect **itself**". So courier *could* forward the caller's credential and
  ask about itself, which would need no second secret at all. It does not, and the
  reason is that the affordance only covers the one token identity is holding:

      mayIntrospect: a token caller may read ITSELF and nothing else.

  Any other tenant's token is a 403. Forwarding the caller's credential would
  therefore work **only** for the single account that happens to own courier's own
  service token, which is a door that is shut for every real tenant and open for
  exactly one — the worst shape a credential can have. See the packet report:
  identity's contract as implemented has no credential a service can use to
  introspect an arbitrary tenant token, and courier's resolver reports that as a
  **503** rather than pretending otherwise.


  Every authenticated request is one extra round trip to identity, on the hot
  path. Caching is not an option that was weighed and declined on latency: a
  cached introspection answer is a **revocation that has not taken effect yet**,
  and the answer courier would serve from it is `account_id` — so a cached entry
  is an account-scoped grant that survives the operator revoking the credential.
  The alternative, a short TTL, is the same hole with a timer on it.

  What that costs is real and is the price of this design: **courier's API
  latency now includes identity's, and identity's outage is courier's outage.**
  Both show up as a 503, which is a retryable status on the caller's side.


  identity unreachable, slow, 5xx, 401, 403, or answering in a shape courier
  cannot read is `{:error, :unavailable}`, which the plug turns into a **503**.
  Never "allow the request": a resolver that fails open under load is worse than
  `Courier.Principal.Reject`, because it fails *silently*.

  And identity's own **401 and 403 are courier's problem, not the caller's**,
  which is why they are a 503 rather than a 401. identity answers 401 when the
  credential *courier* presented is not one it accepts, and 403 when that
  credential may not ask about the token it named. Both are facts about this
  deployment. Reporting either as a 401 tells a customer to rotate a token that
  was never the problem, and an operator reads a wall of "invalid credentials"
  when the fault is one environment variable.


      {:ok, principal}              a live token with an account courier can place
      :error                        identity said no — a 401, one answer for every
                                    reason a token is unusable
      {:error, :unavailable}        courier could not find out — a 503


  `Authorization: Bearer <token>` and nothing else. **Not** the `__Host-session`
  cookie: that is identity's browser surface, core's conventions put cookies on
  that surface and not on API traffic, and courier has no session of its own to
  hang one on. A request with no bearer is refused **without calling identity** —
  which is not an optimisation, it is what stops an unauthenticated endpoint being
  a load generator aimed at a dependency.
  """

  require Logger

  alias Courier.Principal.Introspection.Document
  alias Courier.Principal.Introspection.Transport

  @behaviour Courier.Principal.Resolver

  @authorization "authorization"
  @bearer_prefix "Bearer "

  @path "/v1/introspections"

  @impl Courier.Principal.Resolver
  def resolve(conn) do
    case bearer(conn) do
      nil -> :error
      token -> ask_identity(token)
    end
  end

  @doc """
  The base URL of identity's API, from `COURIER_IDENTITY_URL`.

  A default rather than a required variable, and the asymmetry with the token
  beside it is deliberate. A wrong URL produces a 503 on every authenticated
  request, which is loud, diagnosable and retriable — while refusing to boot over
  an unset variable would turn a dependency's address into a stop-the-world
  upgrade gate. The **credential** has no default, because a default credential is
  a credential in version control.

  The fallback is `http://identity:8080` — the same value `config/runtime.exs`
  defaults the variable to, and identity's own port. The two statements of one
  fact are held together by
  `test/courier/principal/introspection_url_test.exs`; a third default that
  disagrees is a resolver pointed at a port nobody listens on.
  """
  @spec url() :: String.t()
  def url, do: Application.get_env(:courier, :identity_url, "http://identity:8080")

  @doc """
  The introspection path, appended to `url/0`.

  Exposed because identity owns the path and a reader checking courier against
  identity's document should be able to see the two strings without leaving this
  repository.
  """
  @spec path() :: String.t()
  def path, do: @path

  @doc """
  courier's own credential for introspection, from `COURIER_IDENTITY_TOKEN`.

  `nil` when unset, which the resolver treats as "cannot find out" — **not** as
  an anonymous caller. A resolver with no credential of its own asking identity
  about callers would be refused a 401 by identity for every request, and turning
  that into courier's own 401 would report courier's misconfiguration as the
  customer's bad token.
  """
  @spec service_token() :: String.t() | nil
  def service_token, do: Application.get_env(:courier, :identity_token)

  @doc """
  The transport this deployment dials identity through.

  Overridable so the suite asserts the seam from both sides. A module from
  configuration rather than a hardcoded `Transport.Req`, and the only reason it
  is not a parameter on `resolve/1` is that a resolver reading its own collaborator
  out of the process dictionary is a resolver whose behaviour depends on what else
  is running.
  """
  @spec transport() :: module()
  def transport,
    do: Application.get_env(:courier, :introspection_transport, Transport.Req)


  defp bearer(conn) do
    with [value] <- Plug.Conn.get_req_header(conn, @authorization),
         "Bearer " <> token <- String.trim(value),
         false <- token == "" do
      token
    else
      _otherwise -> nil
    end
  end

  defp ask_identity(token) do
    with {:ok, service_token} <- service_credential(),
         {:ok, status, body} <-
           transport().post(url() <> @path, headers(service_token), body(token)) do
      document(status, body)
    else
      {:error, reason} -> unavailable("identity could not be reached (#{inspect(reason)})")
      :no_service_credential -> unavailable("no introspection credential is configured")
    end
  end

  defp document(200, body) do
    case Document.from(body) do
      {:ok, principal} -> {:ok, principal}
      :error -> :error
      {:error, :unreadable} -> unavailable("identity answered in a shape courier cannot read")
    end
  end

  defp document(status, _body) do
    unavailable("identity answered #{status}")
  end

  defp service_credential do
    case service_token() do
      token when is_binary(token) and token != "" -> {:ok, token}
      _absent_or_empty -> :no_service_credential
    end
  end

  defp body(token), do: Jason.encode!(%{"token" => token})

  defp headers(service_token) do
    [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"authorization", @bearer_prefix <> service_token}
    ]
  end

  defp unavailable(detail) do
    Logger.warning("[principal] refusing a request: #{detail}")
    {:error, :unavailable}
  end
end
