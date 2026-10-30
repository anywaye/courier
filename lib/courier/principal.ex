defmodule Courier.Principal do
  @moduledoc """
  The caller of a request, as far as courier can tell.

  A struct rather than a bare account id so that what courier knows about a caller
  is visible in one place and adding a field later (a subject, scopes) does not
  change the shape of every call site.

  There is no role here, and that is deliberate: core's OpenAPI conventions say
  "Services do not parse roles out of a `roles` claim — they check `scopes`, or ask
  identity." courier checks `account_id` for tenancy and asks identity about
  capability, so a `role` field on this struct would be a thing nothing reads.


  `Courier.Principal.Introspection` reads the capability set out of identity's
  introspection answer and puts it here, and **nothing in courier reads it to make
  a decision.** That is a decision, not an omission, and it is recorded where the
  decision is made rather than left to be discovered:

  identity's scope vocabulary is a **closed set of six** — `accounts:read`,
  `accounts:write`, `accounts:delete`, `oidc_clients:write`, `audit_log:read`,
  `account_invitations:write` (`internal/apikeys/apikeys.go`, `AllScopes/0`) —
  and **not one of the six scopes courier's own `openapi.yaml` names**
  (`webhooks:read`, `webhooks:write`, `notifications:read`,
  `notifications:write`, `messages:write`) can be minted by it. So a scope check
  written today would refuse every credential identity is able to issue.

  The field is here because this struct is where a caller's facts live and because
  the packet that does enforce them needs somewhere to read them from, and it is
  asserted from both claim names rather than being left unexercised. The day
  identity's vocabulary grows courier's names, the check is one comparison in
  `CourierWeb.Plugs.Principal` and nothing else moves.
  """

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t() | nil,
          subject: String.t() | nil,
          scopes: [String.t()]
        }

  defstruct account_id: nil, subject: nil, scopes: []
end

defmodule Courier.Principal.Resolver do
  @moduledoc """
  The behaviour `CourierWeb.Plugs.Principal` asks who is calling.

  A behaviour with a refusing default rather than a direct JWT call, so the shape
  of "who is calling" is settled now — before the packet that fills it in — and a
  deployment with no verifier configured refuses every webhook request instead of
  serving them to anyone who asks.


  `:error` was the whole vocabulary when this was written, and it was enough for
  a resolver that either knows who is calling or does not. A resolver that has to
  **ask somebody** has a third case that is neither: identity is unreachable, slow,
  or answered with a status courier cannot turn into a claim. That is not an
  anonymous caller and it is not a caller whose credential was refused, and
  answering either of those would be a lie in the direction that costs somebody
  money — a 401 tells a caller with a perfectly good token that their token is the
  problem, and a generated client answers that by rotating the one credential that
  was fine.

  So the answer is `{:error, :unavailable}`, and the plug turns it into a 503. It
  is **fail-closed**: an identity outage is not "allow the request".
  """

  @typedoc """
  `{:ok, principal}` for an authenticated caller, `:error` for anyone else, and
  `{:error, :unavailable}` for a resolver that could not find out.
  """
  @type answer ::
          {:ok, Courier.Principal.t()} | :error | {:error, :unavailable}

  @doc "Resolves the caller of `conn`, or refuses."
  @callback resolve(Plug.Conn.t()) :: answer()
end

defmodule Courier.Principal.Reject do
  @moduledoc """
  The default resolver: it authenticates nobody.

  This is what a deployment gets when `config :courier, :principal` names nothing,
  and it is still the right answer for that case: every authenticated request is a
  401 rather than an unauthenticated read of another account's endpoints. The
  moduledoc used to say "until the identity packet lands" and that half is now
  stale — the packet landed — so what this module is for has changed and the old
  sentence would have left a reader looking for a verifier that is already
    configured.

  **It stays anyway, and it is not redundant with
  `Courier.Principal.Introspection`.** There are two different questions here:

    * *Is a verifier configured?* Unset means nobody has told this deployment who
      to ask, and refusing is the only honest answer to a question courier cannot
      answer.
    * *Is the verifier working?* A configured resolver that cannot reach identity
      answers `{:error, :unavailable}` and the caller gets a 503 that says so,
      which is a diagnosable state. Swapping this module back in would produce a
      401 that says nothing about why — the same failure
      `Courier.ErrorRelay.Sink.Noop` refuses to accept, one layer up.

  A caller that *is* authenticated still needs this plug configured to something
  that can see it, which is a deliberate two-step rather than a default that
  guesses: a default that trusted a header would be an authentication bypass with
  a config file attached.
  """

  @behaviour Courier.Principal.Resolver

  @impl Courier.Principal.Resolver
  def resolve(_conn), do: :error
end
