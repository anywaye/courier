defmodule Courier.BounceCorrelationTest do
  @moduledoc """
  A message courier sends and a report the provider makes about it can be joined
  on a value both sides hold.

  ## The defect this file is the proof for

  A real password reset sent through Cloudflare was recorded as
  `outbox_events.subject = courier-2be282f1-…` — courier's own generated id,
  which `Courier.Deliver` writes into the `Message-ID` header. Cloudflare owns
  the `Message-ID`, refuses a caller-supplied one, and reports its own
  `result.message_id`, so the provider's bounce report quoted an id courier had
  recorded **nowhere**. `Courier.InboundReports` logged `courier holds no sent
  message for Message-ID "…"`, recorded the suppression, and published no event:
  nothing could say which send, which user, or which notification type the
  bounce was about.

  So courier now records the adapter's receipt id beside its own, in the same
  transaction as the send (`outbox_events.provider_message_id`), and
  `Courier.InboundReports` joins a report on either id. This file drives both
  halves for real: a send through the real `Courier.Adapters.CloudflareEmail`
  against `Courier.TestSupport.CloudflareServer`, and a signed report through
  the real `POST /inbound/resend` route.

  ## Why `async: false`

  These tests replace `config :courier, Courier.Mailer` and
  `config :swoosh, :api_client`, which the whole VM shares, so two of them
  running at once would deliver through each other's adapter — the same reason
  `cloudflare_delivery_test.exs` and `smtp_delivery_test.exs` are `async: false`.
  """

  use CourierWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Courier.Deliver
  alias Courier.Events
  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.TestSupport.CloudflareServer
  alias Courier.TestSupport.FakeResend

  @account_id "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  # The id the fixture provider assigns and its report quotes. Not courier's own
  # shape on purpose: the whole point is an id courier did not mint.
  @provider_id "a1b2c3d4-provider-owned"

  @moduletag account: @account_id

  setup do
    previous_mailer = Application.get_env(:courier, Courier.Mailer)
    previous_api_client = Application.get_env(:swoosh, :api_client)

    on_exit(fn ->
      Application.put_env(:courier, Courier.Mailer, previous_mailer)
      Application.put_env(:swoosh, :api_client, previous_api_client)
    end)

    {:ok, server, port} = CloudflareServer.start_link()
    put_adapter(port)

    %{server: server}
  end

  # The address each test mints. `email_suppressions` has no `account_id` and its
  # rows are permanent, so an address another test also reported would decide this
  # one's outcome.
  defp address, do: "correlation-#{System.unique_integer([:positive])}@example.com"

  defp payload(recipient) do
    %{user_id: @user_id, email: recipient, name: "Kaka"}
  end

  # The fixture provider answers a 2xx whose `result.message_id` is the id its
  # own reports quote — the shape the Cloudflare adapter reports as the receipt
  # id.
  defp with_provider_id(server) do
    CloudflareServer.set_response(server, 200, """
    {"success":true,"errors":[],"messages":[],"result":{"delivered":["ok@example.com"],"permanent_bounces":[],"queued":[],"suppressed_recipients":[],"message_id":"#{@provider_id}"}}
    """)
  end

  defp put_adapter(port) do
    Application.put_env(:courier, Courier.Mailer,
      adapter: Courier.Adapters.CloudflareEmail,
      api_key: "cloudflare-test-key-not-a-real-secret",
      account_id: "test-account-id-abc123",
      base_url: "http://127.0.0.1:#{port}"
    )

    Application.put_env(:swoosh, :api_client, Swoosh.ApiClient.Req)
    Application.ensure_all_started(:req)
  end

  defp sends,
    do: Repo.all(from event in OutboxEvent, where: event.type == ^Events.delivered_type())

  defp bounced(recipient) do
    Enum.filter(
      Repo.all(from event in OutboxEvent, where: event.type == ^Events.bounced_type()),
      &(&1.data["email"] == recipient)
    )
  end

  defp deliver_report(body) do
    {body, headers} = FakeResend.signed(body)

    headers
    |> Enum.reduce(build_conn(), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> put_req_header("content-type", "application/json")
    |> post("/inbound/resend", body)
  end

  # ---------------------------------------------------------------------------
  # The provider's id is recorded beside courier's, in the send's transaction
  # ---------------------------------------------------------------------------

  describe "a send through the Cloudflare adapter" do
    test "records the provider's receipt id, and keeps courier's own", %{server: server} do
      with_provider_id(server)
      recipient = address()

      assert {:ok, result} = Deliver.welcome(payload(recipient))

      # courier's own id is unchanged: it is what the platform's events carry,
      # and every existing row and test depends on it.
      assert result.message_id =~ ~r/^courier-[0-9a-f-]+$/

      assert [event] = sends()
      assert event.subject == result.message_id
      assert event.provider_message_id == @provider_id
    end

    test "a receipt with no id records no provider id, and invents none" do
      # The default fixture response is a 2xx with `delivered` and no
      # `message_id` — a shape the adapter supports deliberately. The send still
      # succeeds and the correlation column stays empty.
      recipient = address()

      assert {:ok, result} = Deliver.welcome(payload(recipient))

      assert [event] = sends()
      assert event.subject == result.message_id
      assert event.provider_message_id == nil
    end
  end

  # ---------------------------------------------------------------------------
  # A report quoting the provider's id finds the send — the packet's whole point
  # ---------------------------------------------------------------------------

  describe "a report quoting the provider's id" do
    test "resolves to the send instead of warning, and publishes the bounced event",
         %{server: server} do
      with_provider_id(server)
      recipient = address()

      assert {:ok, result} = Deliver.welcome(payload(recipient))

      # A report that quotes the provider's id — NOT courier's — which is the
      # id the provider's own reports carry. Before this packet this produced
      # the "courier holds no sent message" warning and no event.
      log =
        capture_log(fn ->
          conn =
            deliver_report(FakeResend.bounce(recipients: [recipient], message_id: @provider_id))

          assert conn.status == 200

          assert Jason.decode!(conn.resp_body)["data"]["events"] == 1,
                 "the report was recorded but resolved to no send: #{conn.resp_body}"
        end)

      refute log =~ "holds no sent message",
             "the join did not use the provider's id: #{log}"

      # The published event names the SEND courier made, on courier's own id —
      # the provider's id resolved the join; it is not what goes on the bus.
      assert [event] = bounced(recipient)
      assert event.subject == result.message_id

      assert event.data == %{
               "message_id" => result.message_id,
               "user_id" => @user_id,
               "notification_type" => "welcome",
               "email" => recipient
             }
    end

    test "a report quoting courier's own id still resolves, with a provider id recorded",
         %{server: server} do
      # The change is additive: a provider (or a hand-built report) that quotes
      # courier's `Message-ID` keeps working, whether or not a provider id is
      # stored beside it.
      with_provider_id(server)
      recipient = address()

      assert {:ok, result} = Deliver.welcome(payload(recipient))

      log =
        capture_log(fn ->
          conn =
            deliver_report(
              FakeResend.bounce(
                recipients: [recipient],
                message_id: "<#{result.message_id}@cafaye.com>"
              )
            )

          assert conn.status == 200
          assert Jason.decode!(conn.resp_body)["data"]["events"] == 1
        end)

      refute log =~ "holds no sent message"
      assert [event] = bounced(recipient)
      assert event.subject == result.message_id
    end

    test "an id courier holds neither column for still warns and publishes nothing" do
      # The warning is not weakened into silence. A receipt with no provider id
      # leaves nothing to correlate against, so a report quoting an id courier
      # never held is the honest "no sent message" case.
      recipient = address()

      assert {:ok, _result} = Deliver.welcome(payload(recipient))

      log =
        capture_log(fn ->
          conn =
            deliver_report(
              FakeResend.bounce(
                recipients: [recipient],
                message_id: "<never-issued@another-provider.example>"
              )
            )

          assert conn.status == 200
          assert Jason.decode!(conn.resp_body)["data"]["events"] == 0
        end)

      assert log =~ "holds no sent message"
      assert bounced(recipient) == []
      # The message courier DID send is untouched: an unattributable bounce says
      # nothing about whether it arrived.
      assert length(sends()) == 1
    end
  end
end
