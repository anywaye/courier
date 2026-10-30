defmodule CourierWeb.InboundControllerConfigTest do
  @moduledoc """
  `POST /inbound/resend` when **courier** is the thing that is wrong.


  `Application.put_env/3` is the whole VM. A test that changes it has to be
  `async: false`, and a module cannot be both `async: true` and `async: false` —
  so the case lives here. `AGENTS.md` states the rule and names three files that
  keep to it: `ProcessOutboxWorkerConfigTest`, `WebhookEndpointsConfigTest` and
  `DeliverWebhookWorkerBudgetTest`. This is the fourth, for the same reason and no
  new one: a test that changes application env belongs in a `*ConfigTest`.


  Exactly one variable: whether courier holds a signing secret for the provider
  the route is for. Everything else — the request, the signature, the body, the
  provider — is courier's real machinery, so the assertion is about courier
  answering a question about its own configuration and not about a mock.


  **`Courier.Inbound.Signature`'s moduledoc raises this objection by name**: "a
  route answering 500 to a misconfigured secret is indistinguishable from one
  under attack, and the operator's first question would be the wrong one." So the
  two are told apart by status, and this file is the half of that claim which
  needs a misconfigured courier to hold:

    * no secret at all → **500**, naming the variable to set;
    * a secret that is present but undecodable → **500** too, because it is the
      same defect one layer in (`Courier.Inbound.Signature.fetch_key/1` refusing
      what `runtime.exs` was happy to store);
    * a secret that does not match the request → **401**, and that is
      `inbound_controller_test.exs`'s case.

  The cost of the split is one 500 a forged request cannot reach, because a forger
  cannot make courier's own configuration wrong. The benefit is that an operator
  looking at a 500 gets the right first question, which is the whole of it.
  """

  use CourierWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Courier.Suppressions
  alias Courier.TestSupport.FakeResend

  @path "/inbound/resend"
  @address "inbound-config-test@example.com"

  setup do
    original = Application.get_env(:courier, :inbound_secrets)

    on_exit(fn -> Application.put_env(:courier, :inbound_secrets, original) end)

    :ok
  end

  defp deliver(body, headers) do
    headers
    |> Enum.reduce(build_conn(), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> put_req_header("content-type", "application/json")
    |> post(@path, body)
  end

  defp deliver_signed(body) do
    {body, headers} = FakeResend.signed(body)
    deliver(body, headers)
  end

  defp problem(conn), do: Jason.decode!(conn.resp_body)

  describe "courier holds no secret for the provider" do
    test "a signed report is a 500 naming the variable, and records nothing" do
      Application.put_env(:courier, :inbound_secrets, %{})

      log =
        capture_log(fn ->
          conn = deliver_signed(FakeResend.bounce(recipients: [@address]))

          assert conn.status == 500

          assert get_resp_header(conn, "content-type") |> List.first() =~
                   "application/problem+json"

          envelope = problem(conn)

          assert envelope["code"] == "internal"
          assert envelope["type"] == "https://docs.anywaye.com/errors/internal"
          assert envelope["detail"] =~ "COURIER_INBOUND_RESEND_SECRET"
          assert is_binary(envelope["trace_id"]) and envelope["trace_id"] != ""

          assert Suppressions.history(@address) == []
        end)

      assert log =~ "COURIER_INBOUND_RESEND_SECRET"
    end

    test "an UNSIGNED report is also a 500, and the secret is asked for first" do
      Application.put_env(:courier, :inbound_secrets, %{})

      capture_log(fn ->
        conn = deliver(FakeResend.bounce(recipients: [@address]), %{})

        assert conn.status == 500
        assert problem(conn)["detail"] =~ "COURIER_INBOUND_RESEND_SECRET"
      end)
    end

    test "an empty string is no secret" do
      Application.put_env(:courier, :inbound_secrets, %{"resend" => ""})

      capture_log(fn ->
        conn = deliver_signed(FakeResend.bounce(recipients: [@address]))

        assert conn.status == 500
        assert Suppressions.history(@address) == []
      end)
    end

    test "a secret for a DIFFERENT provider is no secret for this one" do
      Application.put_env(:courier, :inbound_secrets, %{"postmark" => FakeResend.secret()})

      capture_log(fn ->
        assert deliver_signed(FakeResend.bounce(recipients: [@address])).status == 500
      end)
    end
  end

  describe "a secret courier holds and cannot use" do
    test "is a 500 too, and it is the same defect one layer in" do
      Application.put_env(:courier, :inbound_secrets, %{"resend" => "not-a-svix-secret"})

      log =
        capture_log(fn ->
          conn = deliver_signed(FakeResend.bounce(recipients: [@address]))

          assert conn.status == 500
          assert problem(conn)["code"] == "internal"
          assert Suppressions.history(@address) == []
        end)

      assert log =~ "COURIER_INBOUND_RESEND_SECRET"
    end
  end

  describe "a courier that is configured" do
    test "does the work, which is what makes the 500 above a diagnostic" do
      Application.put_env(:courier, :inbound_secrets, %{"resend" => FakeResend.secret()})

      conn = deliver_signed(FakeResend.bounce(recipients: [@address]))

      assert conn.status == 200
      assert problem(conn)["data"]["recorded"] == 1
      assert [_row] = Suppressions.history(@address)
    end

    test "and a no-op provider name in the map is not a configured provider" do
      Application.put_env(:courier, :inbound_secrets, %{"resend" => ""})

      assert Courier.InboundConfig.configured_providers() == []

      capture_log(fn ->
        assert deliver_signed(FakeResend.bounce(recipients: [@address])).status == 500
      end)
    end
  end

  describe "the stored shape" do
    test "a keyword list does not crash the route" do
      Application.put_env(:courier, :inbound_secrets, resend: FakeResend.secret())

      conn = deliver_signed(FakeResend.bounce(recipients: [@address]))

      assert conn.status == 200
      assert problem(conn)["data"]["recorded"] == 1
      assert [_row] = Suppressions.history(@address)
    end

    test "and a shape courier cannot read at all is a 500 naming the variable" do
      Application.put_env(:courier, :inbound_secrets, "resend")

      capture_log(fn ->
        conn = deliver_signed(FakeResend.bounce(recipients: [@address]))

        assert conn.status == 500
        assert problem(conn)["detail"] =~ "COURIER_INBOUND_RESEND_SECRET"
        assert Suppressions.history(@address) == []
      end)
    end
  end
end
