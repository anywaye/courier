defmodule CourierWeb.TenantScopeTest do
  @moduledoc """
  The tenant scope spans the request's database work — write and read.

  ## THE BUG THIS FILE PINS

  `CourierWeb.Plugs.TenantIdentity` opens its transaction around `fn -> conn end`
  — no database work — and commits before the `:idempotent` plug and the
  controller run. In production the commit discards the transaction-local
  `anywaye.account_id`, so downstream runs with no identity: protected writes
  raise `42501` and protected reads return zero rows. Every authenticated
  route's protected-table access is broken, not just mail.

  ## WHY PLUG-LEVEL, AND WHY `begin_account(nil)`

  The full request path cannot show this in-suite: the sandbox wraps the test in
  a transaction, so the plug's `Repo.transaction/1` is a SAVEPOINT whose release
  does NOT discard the setting (`Courier.DataCase` measures this). In-suite the
  downstream sees the identity; in production the COMMIT discards it
  (`Courier.TenancyTest` measures that half). So this file drives the downstream
  seam directly — `CourierWeb.Plugs.Idempotency`, the first protected-table
  writer on the path — from the state production leaves behind: the plug's
  transaction committed, the identity discarded. `begin_account(nil)` is that
  state, not a second bug: `nil` clears, and a cleared identity is what a
  committed-away one reads as.

  The account on `conn.assigns.current_account` is `CourierWeb.Plugs.Principal`'s
  stash, which still runs first; the database half is what is under test.

  ## WHY `async: false`, WITH A REASON

  The pool-recovery test deliberately fails more transactions than any test pool
  holds. A leaked checkout would starve a concurrently running test's checkout,
  so this file does not share the pool while it proves the pool is intact.
  """

  use CourierWeb.ConnCase, async: false

  alias Courier.Repo
  alias Courier.Tenancy
  alias CourierWeb.Plugs.Idempotency, as: IdempotencyPlug

  @account "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  # No `@moduletag account:` on purpose: the file's ambient identity is none,
  # which is the production downstream state once the plug's transaction has
  # committed. A tag would set the identity the test is proving the request
  # carries itself.

  # A conn the way `Principal` leaves it: the account stashed, nothing else.
  defp authed_conn(key) do
    build_conn()
    |> Plug.Conn.assign(:current_account, @account)
    |> Plug.Conn.put_req_header("idempotency-key", key)
  end

  defp address, do: "scope-#{System.unique_integer([:positive])}@example.com"

  defp message_body(overrides \\ %{}) do
    Map.merge(
      %{"type" => "welcome", "user_id" => @user_id, "to" => address(), "name" => "Kaka"},
      overrides
    )
  end

  describe "the request's protected-table access, with no ambient identity" do
    test "an idempotency claim (write) and its lookup (read) both succeed" do
      # Production's post-COMMIT state, stated rather than inherited: whatever a
      # previous transaction set is gone. `Courier.TenancyTest` measures that a
      # COMMIT discards `is_local`; this is the downstream half of that fact.
      Tenancy.begin_account(Repo, nil)

      key = Ecto.UUID.generate()

      # WRITE: the first protected-table write on the request path. On the
      # broken arrangement this raises, because no transaction holds the
      # identity anymore:
      #
      #     ** (Postgrex.Error) ERROR 42501 new row violates row-level security
      #        policy for table "idempotency_keys"
      conn = IdempotencyPlug.call(authed_conn(key), IdempotencyPlug.init([]))

      refute conn.halted,
             "a first presentation of an Idempotency-Key must claim, not refuse"

      # READ: the same key presented again must FIND the row the claim wrote. An
      # `in_flight` row answers 409 `conflict` ("still being processed") — the
      # status is not the point, reaching the row is: a scope that could not
      # read would answer as though the row did not exist.
      again = IdempotencyPlug.call(authed_conn(key), IdempotencyPlug.init([]))

      assert again.halted
      assert again.status == 409
    end
  end

  describe "the pool on error paths" do
    test "a request that blows up mid-transaction returns its connection" do
      # More failures than any test pool holds (`pool_size` is
      # `schedulers * 2`): one leaked checkout per failure would exhaust the
      # pool and the scoped write below would time out waiting for one.
      for _ <- 1..32 do
        assert_raise RuntimeError, "boom mid-request", fn ->
          Tenancy.with_account(Repo, @account, fn -> raise "boom mid-request" end)
        end
      end

      # The pool is intact: scoped work succeeds immediately afterwards, with
      # no sleep and no retry.
      Tenancy.begin_account(Repo, nil)

      key = Ecto.UUID.generate()
      conn = IdempotencyPlug.call(authed_conn(key), IdempotencyPlug.init([]))
      refute conn.halted

      # And a full request is still served on the same pool.
      full =
        build_conn()
        |> Plug.Conn.put_req_header("x-courier-account", @account)
        |> post("/v1/webhook_endpoints")

      assert full.status in [200, 201, 422]
    end
  end

  describe "acceptance: an authenticated send's write and read" do
    test "POST /v1/messages is accepted, and its retry is replayed" do
      key = Ecto.UUID.generate()
      headers = [{"x-courier-account", @account}, {"idempotency-key", key}]
      payload = message_body()

      first =
        Enum.reduce(headers, build_conn(), fn {name, value}, conn ->
          Plug.Conn.put_req_header(conn, name, value)
        end)
        |> post("/v1/messages", payload)

      assert first.status == 200
      assert Jason.decode!(first.resp_body)["data"]["status"] == "accepted"

      second =
        Enum.reduce(headers, build_conn(), fn {name, value}, conn ->
          Plug.Conn.put_req_header(conn, name, value)
        end)
        |> post("/v1/messages", payload)

      assert second.status == 200

      assert Plug.Conn.get_resp_header(second, "idempotency-replayed") == ["true"],
             "the retry must be answered from the stored response, which proves " <>
               "the request read back the row its own scope wrote"
    end
  end

  describe "the pipeline the scope hangs off" do
    # The `/v1` routes. `route_info/4` is given a **string** verb because
    # the atom form answers `:error` for every path here — the same form
    # `router_test.exs` uses.
    @v1_routes [
      {"GET", "/v1/notification_preferences/:user_id"},
      {"PUT", "/v1/notification_preferences/:user_id"},
      {"GET", "/v1/webhook_endpoints"},
      {"GET", "/v1/webhook_endpoints/:id"},
      {"PATCH", "/v1/webhook_endpoints/:id"},
      {"DELETE", "/v1/webhook_endpoints/:id"},
      {"POST", "/v1/webhook_endpoints"},
      {"POST", "/v1/webhook_endpoints/:id/test"},
      {"POST", "/v1/messages"},
      {"GET", "/v1/notifications"},
      {"GET", "/v1/notifications/unread_count"},
      {"POST", "/v1/notifications/:id/seen"},
      {"POST", "/v1/notifications/:id/read"}
    ]

    @unauthenticated [
      {"GET", "/healthz"},
      {"GET", "/readyz"},
      {"GET", "/unsubscribe/:token"},
      {"POST", "/unsubscribe/:token"},
      {"POST", "/inbound/resend"}
    ]

    test "every /v1 route is behind :authenticated, so a new route inherits the principal" do
      for {method, path} <- @v1_routes do
        assert %{pipe_through: pipe_through} =
                 Phoenix.Router.route_info(CourierWeb.Router, method, path, "")

        assert :authenticated in pipe_through, "#{method} #{path} must be behind :authenticated"
      end
    end

    test "the unauthenticated surfaces are NOT behind it, by name" do
      for {method, path} <- @unauthenticated do
        assert %{pipe_through: pipe_through} =
                 Phoenix.Router.route_info(CourierWeb.Router, method, path, "")

        refute :authenticated in pipe_through,
               "#{method} #{path} must not be behind :authenticated: #{inspect(pipe_through)}"
      end
    end

    test ":authenticated holds no transaction-scoping plug" do
      # The removed shape, guarded against by name: a plug in this pipeline
      # that opened a transaction around the rest of the request committed
      # before the controller ran, discarding the transaction-local identity
      # and breaking every authenticated route's protected-table access with
      # a 42501. The scope now lives in each action and in the `:idempotent`
      # plug, where a transaction can wrap the work. Read off the ROUTER'S OWN
      # SOURCE rather than a list kept here, because a list kept here can
      # agree with a router that has the plug back.
      source = File.read!(Path.join(__DIR__, "../../../lib/courier_web/router.ex"))

      [_, body] =
        Regex.run(~r/pipeline :authenticated do\n(.*?)\n  end/s, source) ||
          flunk("router.ex has no `pipeline :authenticated do` block to read")

      refute body =~ "TenantIdentity",
             "no transaction-scoping plug may return to :authenticated:\n\n#{body}"

      assert body =~ "CourierWeb.Plugs.Principal",
             ":authenticated authenticates — the plug that stashes the account:\n\n#{body}"
    end
  end
end
