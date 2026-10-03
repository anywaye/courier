defmodule CourierWeb.Plugs.TenantIdentity do
  @moduledoc """
  Puts the account on the connection, for the length of the request.

  ## WHAT IT IS FOR

  `CourierWeb.Plugs.Principal` puts an account on the `conn`. This plug puts the
  same account where **Postgres** can see it, so the row-level-security policies
  kit's substrate installed on `idempotency_keys`, `notification_preferences` and
  `webhook_endpoints` have an identity to key on.

  Without it the policies are installed and inert: the role courier connects as is
  a policy subject (kit creates it `NOSUPERUSER`, and the migration sets
  `FORCE ROW LEVEL SECURITY`), so every read of those three tables returns **zero
  rows** — no error, nothing in the log. A webhook endpoint list answering `[]`
  and an idempotency lookup finding nothing are the two shapes it takes. See
  `Courier.Tenancy` for the measurement and for why a development machine did not
  see it.

  ## WHY IT IS IN THE `:authenticated` PIPELINE AND NOT ITS OWN

  Because the ordering is the whole mechanism and the router is where ordering is
  declared. `:authenticated` is *who is asking*, then *tell the database who is
  asking*, and a route added to that pipeline gets the identity without anybody
  remembering. A separate pipeline a caller could pipe through in either order
  would be the failure this packet exists to prevent — "too late, a query ran
  before the identity was set".

  `CourierWeb.Plugs.Principal` **halts** on an unauthenticated caller, so this
  plug never runs for one, and a 401 never opens a transaction. That is the right
  order and it is also why the negative control is a property of the *database*
  rather than of the request: there is no HTTP request that reaches a protected
  table with no identity, because the one route that has no account on it is
  answered before this plug exists.

  ## WHY A TRANSACTION, AND WHY IT IS THIS TRANSACTION

  `cafaye.begin_account/1` is `set_config(…, is_local := true)`. Transaction-local
  is not tidiness, it is the entire reason this control cannot leak:

    * outside a transaction the value expires at the end of the statement that set
      it, so a query that forgot to open one reads **zero rows** — safe, and loud;
    * inside one it is discarded by `COMMIT` **or** `ROLLBACK`, in the database,
      with nothing for courier to forget.

  So the identity cannot outlive the request. A session-level `set_config` on a
  pooled connection could, and that is the cross-tenant leak this arrangement is
  built to make impossible: `reports/courier-row-level-security/prove-identity-leak.sh`
  measures it on a **single-connection pool**, which is the worst case a pool can
  present, and it is red when the local scoping is replaced by a session-scoped
  one.

  `Courier.Tenancy` owns the SQL and the moduledoc states what the transaction
  costs (a connection held for the request; the response leaves before the
  COMMIT). This plug is only the wiring.

  ## WHAT IT DOES WHEN THERE IS NO ACCOUNT

  `cafaye.begin_account(NULL)` **clears** the identity, so the answer is zero
  rows rather than an error. There is no branch here that raises, and that is the
  substrate's design arriving from the other end: a policy that raised on an absent
  identity would tell a caller its request was not authenticated, and a caller can
  be made to believe that about somebody else's request.
  """

  import Plug.Conn

  alias Courier.Tenancy
  alias CourierWeb.Problem

  @doc false
  def init(opts), do: opts

  @doc """
  Runs the rest of the pipeline inside one transaction carrying `current_account`.

  The transaction is the request: it opens here, before the `:idempotent` plug
  and before the controller, and it closes when the pipeline returns.
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    account_id = conn.assigns[:current_account]

    case Tenancy.with_account(Courier.Repo, account_id, fn -> conn end) do
      {:ok, conn} -> conn
      # Unreachable by construction — `fun` is `fn -> conn end` and never calls
      # `Repo.rollback`. Handled rather than left to a `MatchError`, because a
      # security control that raises on a shape it cannot explain is a control
      # whose failure nobody has diagnosed. If it ever is reachable, the answer is
      # the same shape the rest of courier uses for "a dependency did not work":
      # a 503 the caller may retry.
      {:error, _reason} -> unavailable(conn)
    end
  end

  # No reason in the body, on the same rule as `CourierWeb.Plugs.Principal`'s
  # 503: what went wrong is in courier's log under this request's `trace_id`, and
  # a detail naming it would tell an unauthenticated caller about this
  # deployment's plumbing.
  defp unavailable(conn) do
    conn
    |> Problem.send(
      503,
      :unavailable,
      "courier could not scope this request to an account, so it is not serving it."
    )
    |> halt()
  end
end
