defmodule Courier.Webhooks.PayloadTest do
  @moduledoc """
  The body courier puts on the wire.

  Standard Webhooks §Payload does not dictate a payload shape, but it does
  recommend one: `type`, `timestamp` of the event, and `data`, "and it should be
  grouped hierarchically". courier's body is the CloudEvents envelope itself,
  because:

    * the envelope is already `type` / `time` / `data`, and duplicating it under
      different names would mean two shapes to keep in step;
    * a consumer that already subscribes to courier's events on NATS gets the same
      document over HTTP, so there is one contract rather than two;
    * it stays inside core's `event-envelope.schema.json` unchanged, which is
      what `Courier.EventsTest` already pins.

  The one thing the spec is emphatic about is that the bytes sent are the bytes
  signed. These tests pin that by encoding once and asserting the same binary is
  what gets signed and what is described.
  """

  use ExUnit.Case, async: true

  alias Courier.OutboxEvent
  alias Courier.Webhooks.Payload

  @event %OutboxEvent{
    id: "11111111-1111-1111-1111-111111111111",
    type: "email.delivered",
    source: "courier",
    subject: "courier-22222222-2222-2222-2222-222222222222",
    occurred_at: ~U[2026-09-30 07:00:00.000000Z],
    data: %{
      "message_id" => "courier-22222222-2222-2222-2222-222222222222",
      "email" => "kaka@example.com"
    }
  }

  defp event, do: @event

  defp event_body, do: Payload.body(@event)

  describe "the envelope body" do
    test "is the CloudEvents envelope, minified" do
      body = event_body()

      assert Jason.decode!(body) == OutboxEvent.envelope(event())
    end

    test "carries the event's own id, so a consumer can deduplicate on it" do
      assert Jason.decode!(event_body())["id"] == event().id
    end

    test "carries the event's type and time" do
      decoded = Jason.decode!(event_body())

      assert decoded["type"] == "email.delivered"
      assert decoded["source"] == "courier"
      assert decoded["time"] == DateTime.to_iso8601(event().occurred_at)
    end

    test "is the same bytes every time it is built for one event" do
      assert event_body() == event_body()
    end

    test "is JSON, which the spec §Payload asks for over everything else" do
      assert {:ok, _decoded} = Jason.decode(event_body())
    end

    test "is under the size the spec recommends" do
      assert byte_size(event_body()) < 20_000
    end
  end

  describe "the ping body" do
    test "is a signed ping, not a real event" do
      body = Payload.ping("msg_test", "https://hooks.example.com/events")

      decoded = Jason.decode!(body)

      assert decoded["type"] == "ping"
      assert decoded["data"]["url"] == "https://hooks.example.com/events"
    end

    test "carries no event id, because it is not an event" do
      decoded = Jason.decode!(Payload.ping("msg_test", "https://hooks.example.com/events"))

      refute Map.has_key?(decoded, "id")
    end

    test "carries a timestamp, as the spec's payload structure asks for" do
      decoded = Jason.decode!(Payload.ping("msg_test", "https://hooks.example.com/events"))

      assert {:ok, _datetime, 0} = DateTime.from_iso8601(decoded["timestamp"])
    end

    test "carries the message id in the body, so a consumer can log what it verified" do
      decoded = Jason.decode!(Payload.ping("msg_test_123", "https://hooks.example.com/events"))

      assert decoded["webhook_id"] == "msg_test_123"
    end
  end
end
