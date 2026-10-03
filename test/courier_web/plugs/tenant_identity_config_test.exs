defmodule CourierWeb.Plugs.TenantIdentityConfigTest do
  @moduledoc """
  The plug is on every account-scoped route, in the right order, and the
  unauthenticated surfaces are untouched.

  ## WHY `async: false`, WITH A REASON

  It asserts over the router's own resolution rather than over a list kept beside
  it, and it drives real requests through the real endpoint.

  ## WHAT IT CANNOT PROVE, AND WHERE THAT IS PROVED INSTEAD

  Not that the policies refuse a cross-account read, and not that the identity
  cannot outlive its transaction. Both are properties of the ROLE and of the
  TRANSACTION BOUNDARY, and `config/test.exs` supplies neither: it connects as
  `postgres`, which is a superuser (`rolbypassrls = t`) so it bypasses RLS
  whatever `FORCE` says, and it runs inside `Ecto.Adapters.SQL.Sandbox`'s
  transaction, which turns `Repo.transaction` into a SAVEPOINT.
  `Courier.TenancyTest`'s moduledoc carries both measurements. The proofs are
  `reports/courier-row-level-security/prove*.sh`.

  So this file asserts the three things that ARE observable in-suite and are the
  ones whose absence caused the finding: the plug is on every `/v1` route, it is
  after `Principal`, and an unauthenticated caller never reaches it.
  """

  use CourierWeb.ConnCase, async: false

  alias Courier.Repo
  alias Courier.Tenancy
  alias CourierWeb.Plugs.Principal

  # The nine `/v1` routes. `route_info/4` is given a **string** verb because the
  # atom form answers `:error` for every path here — and a `%{pipe_through:
  # pipelines}` match against `:error` is a match that fails, which would make
  # this file red rather than quietly passing, but it would be red for a reason
  # that has nothing to do with the control. Same form `router_test.exs` uses.
  @v1_routes [
    {"GET", "/v1/notification_preferences/:user_id"},
    {"PUT", "/v1/notification_preferences/:user_id"},
    {"GET", "/v1/webhook_endpoints"},
    {"GET", "/v1/webhook_endpoints/:id"},
    {"PATCH", "/v1/webhook_endpoints/:id"},
    {"DELETE", "/v1/webhook_endpoints/:id"},
    {"POST", "/v1/webhook_endpoints"},
    {"POST", "/v1/webhook_endpoints/:id/test"},
    {"POST", "/v1/messages"}
  ]

  @unauthenticated [
    {"GET", "/healthz"},
    {"GET", "/readyz"},
    {"GET", "/unsubscribe/:token"},
    {"POST", "/unsubscribe/:token"},
    {"POST", "/inbound/resend"}
  ]

  describe "the pipeline" do
    test ":authenticated is Principal THEN TenantIdentity, and the order is the mechanism" do
      # Read off the ROUTER'S OWN SOURCE rather than a list kept here, because a
      # list kept here can agree with a router that does not have the plug — and
      # this file's whole subject is a plug that has to be on every route.
      #
      # `pipeline :authenticated do … end` is a macro over `plug/2` in source order
      # and Phoenix preserves it, so the byte offset of each plug's name inside the
      # pipeline's own body IS the order. An earlier version of this assertion read
      # the compiled pipe-through module, which answers `:error` for a route
      # resolved without the pipeline — i.e. it would have passed on nothing.
      source = File.read!(Path.join(__DIR__, "../../../lib/courier_web/router.ex"))

      [_, body] =
        Regex.run(~r/pipeline :authenticated do\n(.*?)\n  end/s, source) ||
          flunk("router.ex has no `pipeline :authenticated do` block to read")

      principal_at = :binary.match(body, "CourierWeb.Plugs.Principal") |> elem(0)
      identity_at = :binary.match(body, "CourierWeb.Plugs.TenantIdentity") |> elem(0)

      assert principal_at < identity_at, """
      :authenticated must be Principal THEN TenantIdentity.

      Principal is what puts the account on the conn, so TenantIdentity running
      first would have nothing to write — "a query ran before the identity was
      set", which is one of the two ways this control fails. The pipeline body:

      #{body}
      """
    end

    test "every /v1 route is behind :authenticated, so a new route inherits the identity" do
      for {method, path} <- @v1_routes do
        assert %{pipe_through: pipe_through} =
                 Phoenix.Router.route_info(CourierWeb.Router, method, path, "")

        assert :authenticated in pipe_through, "#{method} #{path} must be behind :authenticated"
      end
    end

    test "the four unauthenticated surfaces are NOT behind it, by name" do
      # Named explicitly rather than counted: a route this packet does not know
      # about should be a red line in a diff, not a silently higher count.
      for {method, path} <- @unauthenticated do
        assert %{pipe_through: pipe_through} =
                 Phoenix.Router.route_info(CourierWeb.Router, method, path, "")

        refute :authenticated in pipe_through,
               "#{method} #{path} must not be behind :authenticated: #{inspect(pipe_through)}"
      end
    end
  end

  describe "over real requests" do
    # Observed from a `before_send` callback, which runs **inside** the transaction
    # `TenantIdentity` opened — the controller's `send_resp` is what triggers it.
    # Reading it after the request returned would be reading it after the COMMIT,
    # which is exactly the thing this suite's sandbox cannot observe (see the
    # moduledoc), and asserting nil there would be a claim about the harness.
    #
    # `send(self(), …)` rather than returning a value, because
    # `Plug.Conn.run_before_send/2` takes the callback's return as the NEW conn and
    # a tuple raises `FunctionClauseError` on the next step. Measured, and the
    # stack names `run_before_send/2` rather than anything about tenancy.
    defp observing(conn) do
      register_before_send(conn, fn conn ->
        send(self(), {:identity_seen, Tenancy.current_account_id(Repo)})
        conn
      end)
    end

    test "the identity is set for the request, read from inside the transaction" do
      account = Ecto.UUID.generate()

      conn =
        build_conn()
        |> put_req_header(Principal.account_header(), account)
        |> observing()
        |> get("/v1/notification_preferences/9f0e1d2c-3b4a-4596-8071-6f5e4d3c2b1a")

      # A user nobody has written preferences for is a 200 with the defaults, so
      # this asserts the request was SERVED rather than merely not refused —
      # without that control a check which read zero rows would also pass.
      assert conn.status == 200

      assert_received {:identity_seen, ^account},
                      "the request ran under a different account than the principal put on the conn"
    end

    test "three accounts over one connection: each request sees only its own account" do
      for account <- [Ecto.UUID.generate(), Ecto.UUID.generate(), Ecto.UUID.generate()] do
        conn =
          build_conn()
          |> put_req_header(Principal.account_header(), account)
          |> observing()
          |> get("/v1/webhook_endpoints")

        assert conn.status == 200
        assert_received {:identity_seen, ^account}
      end
    end

    test "an unauthenticated caller never reaches the identity plug" do
      # `Principal` halts the 401, so `TenantIdentity` never runs and no identity
      # is written. This is the negative control's HTTP half; its other half — that
      # a session with NO identity reads **zero rows**, not every row and not an
      # error — is `Courier.TenancyTest` and `prove.sh`.
      conn = observing(build_conn()) |> get("/v1/webhook_endpoints")

      assert conn.status == 401
      assert_received {:identity_seen, nil}
    end

    test "the surfaces that need no account still answer, and invent no identity" do
      for path <- ["/healthz", "/readyz"] do
        conn = observing(build_conn()) |> get(path)

        assert conn.status == 200, "#{path} must answer"
        assert_received {:identity_seen, nil}, "#{path} invented an account"
      end

      # And the unsubscribe door is reachable: a token courier never issued is a
      # **404**, not a 401 and not a dead route. RFC 8058's reasoning for that
      # exact status is `UnsubscribeControllerTest`'s; this asserts only that the
      # surface survived this packet.
      conn = observing(build_conn()) |> get("/unsubscribe/#{Ecto.UUID.generate()}")

      assert conn.status == 404
      assert_received {:identity_seen, nil}
    end
  end
end
