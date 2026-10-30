defmodule CourierWeb.MessagesControllerConfigTest do
  @moduledoc """
  The two refusals that need configuration changed to reach.

  `async: false` because both swap `config :courier, Courier.Mailer`, and
  application env is VM-global: for the length of this module any other test in
  the suite that delivers mail would deliver it through the substituted adapter
  instead of the Test adapter. `on_exit` restores it before the next test starts.


  Neither case can be reached through `messages_controller_test.exs`, and the
  reasons are the point:

    * **A provider that refuses** needs an adapter that fails.
      `Swoosh.Adapters.Test` cannot fail — it hands the message to the sending
      process and answers `{:ok, %{}}` — so the only way through the real Swoosh
      path is to substitute one. `Courier.DeliverAdapterTest` already does this
      for the context; this file does it for the HTTP answer.
    * **An adapter that cannot deliver** needs the *production* scope, because
      `Test` and `Local` are the correct adapters in the environments that
      configure them and refusing them everywhere would mean the suite could never
      send a mail. `Courier.MailerAdapter.config_env/0` reads
      `Application.get_env(:courier, :environment)`, which is what makes that
      scope reachable from a test at all, and setting it here is the whole reason
      `config_env/0` exists rather than `Mix.env/0`.

  Swapping the mailer is also why the checks here are about courier's own rows and
  never the table's: another test may well be writing outbox rows concurrently
  while this module holds the VM.
  """

  use CourierWeb.ConnCase, async: false

  alias Courier.OutboxEvent
  alias Courier.Repo

  @account "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  defp body(overrides \\ %{}) do
    Map.merge(
      %{"type" => "welcome", "user_id" => @user_id, "to" => "recipient@example.com"},
      overrides
    )
  end

  defp post_authed(payload) do
    build_conn()
    |> put_req_header("x-courier-account", @account)
    |> post(~p"/v1/messages", payload)
  end

  defp problem(conn), do: Jason.decode!(conn.resp_body)

  setup do
    original_mailer = Application.get_env(:courier, Courier.Mailer)
    original_env = Application.get_env(:courier, :environment)

    on_exit(fn ->
      Application.put_env(:courier, Courier.Mailer, original_mailer)
      Application.put_env(:courier, :environment, original_env)
    end)

    :ok
  end

  describe "the provider says no" do
    setup do
      Application.put_env(:courier, Courier.Mailer, adapter: Courier.TestSupport.FailingAdapter)

      :ok
    end

    test "is a 503 the caller can retry, not a 500" do
      conn = post_authed(body())

      assert conn.status == 503
      assert problem(conn)["code"] == "unavailable"
      assert problem(conn)["status"] == 503
      assert problem(conn)["trace_id"] == get_resp_header(conn, "x-trace-id") |> List.first()
    end

    test "is told a retry is safe, because nothing was sent and nothing recorded" do
      conn = post_authed(body())

      assert conn.status == 503
      assert problem(conn)["detail"] =~ "retry"
    end

    test "the provider's own error string is not echoed to the caller" do
      conn = post_authed(body())

      assert conn.status == 503
      refute conn.resp_body =~ "provider_unavailable"
    end

    test "no outbox row is written for a send that did not happen" do
      conn = post_authed(body())

      assert conn.status == 503

      assert Repo.all(OutboxEvent) |> Enum.filter(&(&1.data["user_id"] == @user_id)) == []
    end

    test "the transaction rolled back, so no event claims a delivery" do
      assert post_authed(body()).status == 503

      refute Enum.any?(Repo.all(OutboxEvent), &(&1.data["user_id"] == @user_id))
    end
  end

  describe "the adapter cannot deliver" do
    test "in production the send is refused rather than silently reported as sent" do
      Application.put_env(:courier, :environment, :prod)
      Application.put_env(:courier, Courier.Mailer, adapter: Swoosh.Adapters.Local)

      conn = post_authed(body())

      assert conn.status == 503
      assert problem(conn)["code"] == "unavailable"
    end

    test "the refusal names the variable an operator has to set" do
      Application.put_env(:courier, :environment, :prod)
      Application.put_env(:courier, Courier.Mailer, adapter: Swoosh.Adapters.Local)

      conn = post_authed(body())

      assert problem(conn)["detail"] =~ "COURIER_MAIL_ADAPTER"
    end

    test "neither credential appears in the refusal, in the body or in the log" do
      Application.put_env(:courier, :environment, :prod)

      Application.put_env(:courier, Courier.Mailer,
        adapter: Swoosh.Adapters.Local,
        relay: "smtp.example.com",
        username: "apikey",
        password: "super-secret"
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = post_authed(body())

          assert conn.status == 503
          refute conn.resp_body =~ "apikey"
          refute conn.resp_body =~ "super-secret"
        end)

      refute log =~ "apikey"
      refute log =~ "super-secret"
    end

    test "outside production the test adapter is allowed, because it is the right one there" do
      Application.put_env(:courier, :environment, :test)
      Application.put_env(:courier, Courier.Mailer, adapter: Swoosh.Adapters.Test)

      conn = post_authed(body())

      assert conn.status == 200
    end

    test "an unset adapter is refused in production rather than defaulting" do
      Application.put_env(:courier, :environment, :prod)
      Application.put_env(:courier, Courier.Mailer, [])

      conn = post_authed(body())

      assert conn.status == 503
      assert problem(conn)["code"] == "unavailable"
    end

    test "a refused send writes no outbox row" do
      Application.put_env(:courier, :environment, :prod)
      Application.put_env(:courier, Courier.Mailer, adapter: Swoosh.Adapters.Local)

      assert post_authed(body()).status == 503

      assert Repo.all(OutboxEvent) |> Enum.filter(&(&1.data["user_id"] == @user_id)) == []
    end
  end

  describe "a send refused by the provider can be retried" do
    test "with the same key, and it succeeds once the provider does" do
      key = "44444444-4444-4444-4444-444444444444"
      Application.put_env(:courier, Courier.Mailer, adapter: Courier.TestSupport.FailingAdapter)

      payload = body()

      refused =
        build_conn()
        |> put_req_header("x-courier-account", @account)
        |> put_req_header("idempotency-key", key)
        |> post(~p"/v1/messages", payload)

      assert refused.status == 503

      Application.put_env(:courier, Courier.Mailer, adapter: Swoosh.Adapters.Test)

      retried =
        build_conn()
        |> put_req_header("x-courier-account", @account)
        |> put_req_header("idempotency-key", key)
        |> post(~p"/v1/messages", payload)

      assert retried.status == 200
      assert get_resp_header(retried, "idempotency-replayed") == []
    end
  end
end
