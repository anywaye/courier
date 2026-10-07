defmodule CourierWeb.Plugs.Principal do
  @moduledoc """
  Resolves who is calling, and refuses the request when nobody is.

  ## This is a seam with one implementation, and both directions are closed

  The seam was written when courier had no verifier, and what was settled then is
  still settled:

    * **A request with no principal is a 401, always.** courier never guesses an
      account for an anonymous caller, and it never falls back to a default one.
    * **The account comes from the principal, never from the body.** Every
      controller reads `conn.assigns.current_account` and the context is called
      with that; an `account_id` in a request body is ignored, and the tests say so
      on every action that would be affected.
    * **The account comes from the principal, and the principal's account comes
      from `account_id`.** `Courier.Principal.Introspection.Document` refuses an
      active document that carries no `account_id` and never reads `sub` as one.

  ## Three answers, and why the third is a 503 and not a 401

  `Courier.Principal.Resolver` answers one of three things:

      {:ok, principal}        the caller, on the account identity named
      :error                  nobody — an unauthenticated 401
      {:error, :unavailable}  courier could not find out

  The third case is new, and it is not a detail. identity is a network hop on the
  request path of every authenticated call, and it will be slow or down at some
  point. When it is:

    * **a 401 would be a lie with a cost.** It says "your credential is not
      acceptable". A customer holding a perfectly good token reads that, rotates
      it, and is still refused. So does an operator: a wall of "invalid
      credentials" when the fault is one environment variable.
    * **allowing the request would be worse.** It is the fail-open case, and it
      fails *silently* — which is what makes it worse than `Courier.Principal.
      Reject`. A locked door is at least visibly locked.
    * **so it is a 503 `unavailable`,** the same status courier already sends when
      the mail provider refuses, and the same rule: courier is fine, its dependency
      is not. It is a retryable status on a caller's side and a diagnosable state
      on courier's.

  The 401 this plug sends is **what it always was**, and that is a test rather
  than a promise: `test/courier_web/plugs/principal_config_test.exs` drives the
  same request through both resolvers and asserts the two envelopes are equal
  field for field — `type`, `code`, `status`, `title`, `detail`, `instance`. The
  one field it drops is `trace_id`, and it drops that one **by name** rather than
  by a rule, because that field is per request by design and comparing two
  requests' identities would fail for a reason that has nothing to do with this
  plug.

  ## The header the test resolver reads

  `x-courier-account` is `Courier.TestSupport.HeaderResolver`'s stand-in for the
  verified claim, and it is only ever read when `config :courier, :principal`
  points at that module. **`Courier.Principal.Introspection` ignores it
  entirely**, and that is asserted over a real resolver call rather than left as a
  convention — a header that becomes a fast path is an authentication bypass with
  a config file attached.

  ## Why the account and not a role

  Core's OpenAPI conventions are explicit: "`scopes` for capability, `account_id`
  for tenancy… Services do not parse roles out of a `roles` claim — they check
  `scopes`, or ask identity." courier therefore has no notion of owner / admin /
  member, and the authorization matrix is expressed in those two terms: is there a
  principal, is this their account, and is the action permitted on it. A future
  scope check is one more question in this plug, not a new authorization model —
  and see `Courier.Principal`'s moduledoc for why that check cannot be written
  yet.
  """

  import Plug.Conn

  alias Courier.Principal
  alias CourierWeb.Problem

  @account_header "x-courier-account"

  @doc false
  def account_header, do: @account_header

  @doc """
  Assigns `:current_account` and `:current_principal` from the configured resolver,
  or answers 401 or 503.

  The 401 is courier's problem+json like every other non-2xx, built by
  `CourierWeb.Problem`, so an unauthenticated request is the same shape as every
  other error a client has to parse — and so is the 503.

  `:current_principal` is the whole `Courier.Principal` struct, and it is assigned
  alongside the account because **the account is not the only fact a controller
  needs about the caller.** The notifications reader addresses a recipient by the
  principal's `subject` — the user the token names — and that field is discarded
  here if only the account is kept. Assigning the struct rather than the subject
  alone is the minimal change: one assign, and a controller that later needs
  `scopes` reads it from the same place.
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def init(opts), do: opts

  def call(conn, _opts) do
    case resolver().resolve(conn) do
      {:ok, %Principal{} = principal} ->
        conn
        |> assign(:current_account, principal.account_id)
        |> assign(:current_principal, principal)

      :error ->
        unauthorized(conn)

      {:error, :unavailable} ->
        unavailable(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/problem+json")
    |> send_resp(
      401,
      Jason.encode!(
        Problem.build(
          conn.assigns,
          401,
          :unauthorized,
          "This request needs an authenticated caller."
        )
      )
    )
    |> halt()
  end

  # The 503 carries no reason. identity's status, the dial error and the shape of
  # its answer are all in courier's log under this request's `trace_id`, and a
  # detail that named any of them would tell an unauthenticated caller which
  # credential courier holds and what shape the service on the other side of it
  # is — the same posture `Courier.Inbound.Signature`'s 401 takes.
  defp unavailable(conn) do
    conn
    |> Problem.send(
      503,
      :unavailable,
      "courier could not confirm who is calling, so it is not serving this request."
    )
    |> halt()
  end

  @doc """
  The resolver configured for this deployment.

  Defaults to the one that authenticates nothing, so the absence of a configured
  verifier is a refusal rather than a silent gap. `config/runtime.exs` names
  `Courier.Principal.Introspection` outside test, so the default is what a
  deployment gets when somebody removed that line.
  """
  @spec resolver() :: module()
  def resolver, do: Application.get_env(:courier, :principal, Courier.Principal.Reject)
end
