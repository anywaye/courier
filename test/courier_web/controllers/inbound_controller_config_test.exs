defmodule CourierWeb.InboundControllerConfigTest do
  @moduledoc """
  `POST /inbound/resend` when **courier** is the thing that is wrong.

  ## Why this is its own file and not `async: false` in the other one

  `Application.put_env/3` is the whole VM. A test that changes it has to be
  `async: false`, and a module cannot be both `async: true` and `async: false` —
  so the case lives here. `AGENTS.md` states the rule and names three files that
  keep to it: `ProcessOutboxWorkerConfigTest`, `WebhookEndpointsConfigTest` and
  `DeliverWebhookWorkerBudgetTest`. This is the fourth, for the same reason and no
  new one: a test that changes application env belongs in a `*ConfigTest`.

  ## What is being varied, and why only the secret

  Exactly one variable: whether courier holds a signing secret for the provider
  the route is for. Everything else — the request, the signature, the body, the
  provider — is courier's real machinery, so the assertion is about courier
  answering a question about its own configuration and not about a mock.

  ## Why the answer is 500 and not 401

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

  # Not async: this changes the application environment, which the whole VM shares.
  use CourierWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Courier.Suppressions
  alias Courier.TestSupport.FakeResend

  @path "/inbound/resend"
  # Borrowed rather than minted, because this test is about the secret and not about
  # the address: it asserts nothing was written, and `history/1` on an address no
  # other test mints is an empty list for the right reason.
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

      # The log line is the half that reaches an operator, and it names the
      # variable for the same reason the response does: a 500 with a trace id and
      # no cause is a support ticket.
      assert log =~ "COURIER_INBOUND_RESEND_SECRET"
    end

    test "an UNSIGNED report is also a 500, and the secret is asked for first" do
      # The order, asserted. `Courier.Inbound.Signature` fetches the secret before
      # it reads any header, and the route keeps that order for the reason the
      # verifier gives: a courier with no secret has ONE problem, its own
      # configuration, and it should be told that about every request rather than
      # about whichever request happened to omit a header first. So a request with
      # no headers at all — which against a configured courier is a 401 — is a 500
      # here, and the detail says so.
      Application.put_env(:courier, :inbound_secrets, %{})

      capture_log(fn ->
        conn = deliver(FakeResend.bounce(recipients: [@address]), %{})

        assert conn.status == 500
        assert problem(conn)["detail"] =~ "COURIER_INBOUND_RESEND_SECRET"
      end)
    end

    test "an empty string is no secret" do
      # `COURIER_INBOUND_RESEND_SECRET=` in a compose file produces `""`, and an
      # empty key is as unusable as a missing one — `fetch_key/1` refuses both and
      # for the same reason. The difference between this and the case above is
      # invisible in a dashboard and total here.
      Application.put_env(:courier, :inbound_secrets, %{"resend" => ""})

      capture_log(fn ->
        conn = deliver_signed(FakeResend.bounce(recipients: [@address]))

        assert conn.status == 500
        assert Suppressions.history(@address) == []
      end)
    end

    test "a secret for a DIFFERENT provider is no secret for this one" do
      # The argument for one variable per provider, asserted: a shared variable
      # could not express this state, and a deployment that reached it by editing
      # the wrong key would be verifying this provider's traffic with another
      # provider's key.
      Application.put_env(:courier, :inbound_secrets, %{"postmark" => FakeResend.secret()})

      capture_log(fn ->
        assert deliver_signed(FakeResend.bounce(recipients: [@address])).status == 500
      end)
    end
  end

  describe "a secret courier holds and cannot use" do
    test "is a 500 too, and it is the same defect one layer in" do
      # `config/runtime.exs` only checks that the variable is SET, so a value that
      # is set and undecodable gets past the boot refusal and fails here — with the
      # `whsec_` prefix missing, which is what pasting the wrong field out of a
      # provider's dashboard looks like. The status is 500 for the same reason the
      # missing case is: it is courier's configuration, not the request's.
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
      # The presence half. Without it, a route that answered 500 to everything
      # would pass every refusal above, and "an absence assertion paired with a
      # presence one" is the rule this repository keeps making for exactly this
      # reason: a redaction boundary that deletes everything passes "no canary",
      # and an error handler that fails everything passes "no 200".
      Application.put_env(:courier, :inbound_secrets, %{"resend" => FakeResend.secret()})

      conn = deliver_signed(FakeResend.bounce(recipients: [@address]))

      assert conn.status == 200
      assert problem(conn)["data"]["recorded"] == 1
      assert [_row] = Suppressions.history(@address)
    end

    test "and a no-op provider name in the map is not a configured provider" do
      # `configured_providers/0` is what the boot line prints, so a value it
      # filters out has to be a value the route also refuses — otherwise the log
      # says a surface is not live while the route is serving it.
      Application.put_env(:courier, :inbound_secrets, %{"resend" => ""})

      assert Courier.InboundConfig.configured_providers() == []

      capture_log(fn ->
        assert deliver_signed(FakeResend.bounce(recipients: [@address])).status == 500
      end)
    end
  end

  describe "the stored shape" do
    test "a keyword list does not crash the route" do
      # The shape a config file's keyword shorthand produces. A `BadMapError`
      # here would be a 500 whose log line says nothing about a map, on a route
      # whose only vocabulary is four deliberate statuses — and the symptom would
      # be a crash in a log rather than a sentence.
      #
      # So it is READ rather than raised, and this asserts the reading: courier
      # finds the secret and does the work. `inbound_config_test.exs` separately
      # asserts that the configuration this repository *ships* is a map, because
      # tolerating the wrong shape is not the same as recommending it.
      Application.put_env(:courier, :inbound_secrets, resend: FakeResend.secret())

      conn = deliver_signed(FakeResend.bounce(recipients: [@address]))

      assert conn.status == 200
      assert problem(conn)["data"]["recorded"] == 1
      assert [_row] = Suppressions.history(@address)
    end

    test "and a shape courier cannot read at all is a 500 naming the variable" do
      # Not a map and not a keyword list — the remaining possibility, and the one
      # a typo in a config file can produce. Still a refusal with a sentence in
      # it, never a crash.
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
