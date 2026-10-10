defmodule Courier.Consumers.SubscriberTest do
  @moduledoc """
  The subscription, over a real socket, against a real broker.

  This is the packet's proof, and it is the same shape as the SMTP round-trip
  and the outbox relay's: what stands in for the broker has to speak the
  protocol back, because what is under test is a real `Gnat` connection
  subscribing, a real `MSG` frame arriving, and a real `consumed_events` row
  being written from it. A mock transport would prove the loop calls
  something; this proves what a consumer RECEIVES.

  What the file asserts:

    * the subscription is to the **`identity.>` prefix**, not to the four
      subscribed types — read off the broker's own subscription list;
    * **an `identity.>` event reaching the bus produces exactly one welcome
      mail, and the same event id delivered twice produces one** — the
      packet's central claim, with the dedupe enforced by the
      `consumed_events` primary key and not by anything this test does;
    * an event for a type courier does not subscribe to is still RECORDED and
      reported `skipped` by the loop — the floor of the bus is the prefix, and
      the manifest and the registry are the only two places a subscription is
      decided;
    * a delivery that cannot be recorded is a WARNING naming the topic, with
      no payload in it, and the subscriber survives it and keeps receiving;
    * with no broker there is no subscriber: `supervised_child/0` answers an
      empty list, which is the "no socket, no loop" property
      `Courier.Nats.supervised_child/0` holds on the connection side.

  ## WHY `async: false`

  Two reasons, each disqualifying on its own: `Courier.Nats` is a NAMED
  process and `:nats` is VM-global application env (two async tests would
  fight over both), and the Ecto sandbox is `shared: true` for a synchronous
  case — the subscriber process writes rows on the test's connection.
  """

  use Courier.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias Courier.ConsumedEvent
  alias Courier.Consumers
  alias Courier.Consumers.Subscriber
  alias Courier.Nats
  alias Courier.TestSupport.NatsServer

  setup do
    original = Application.get_env(:courier, :nats)

    server = start_supervised!(NatsServer)
    port = NatsServer.port(server)

    Application.put_env(:courier, :nats, url: "nats://127.0.0.1:#{port}")

    # The connection first, the subscriber after it — the order the
    # application tree uses, because the subscriber subscribes on the
    # connection it asks for.
    start_supervised!({Nats, []})
    start_supervised!(Subscriber)

    on_exit(fn -> Application.put_env(:courier, :nats, original) end)

    %{server: server, port: port}
  end

  # The event identity publishes: `NewUserCreated`'s envelope, transcription
  # not derivation (verified in identity's `internal/outbox/envelope.go`).
  defp envelope do
    %{
      "specversion" => "1.0",
      "id" => "8c9d0e1f-0000-4000-8000-00000000000a",
      "type" => "identity.user.created",
      "source" => "identity",
      "subject" => "9c8d7e6f-1111-4222-8333-444455556666",
      "time" => "2026-10-10T12:00:00Z",
      "data" => %{
        "user_id" => "9c8d7e6f-1111-4222-8333-444455556666",
        "email" => "kaka@example.com"
      }
    }
  end

  # The bytes a publisher puts on the wire, delivered to the broker as
  # published. A plain PUB — the envelope reaches core subscribers the same
  # way a JetStream publish does, and this is the consumer's side.
  defp publish(subject, payload) do
    {:ok, connection} = Nats.connection()
    _ = Gnat.pub(connection, subject, payload)
    :ok
  end

  # The subscription is established from the subscriber's init on the
  # application's connection, so this waits for the FACT to exist rather than
  # assuming it. Each poll is a `GenServer.call` on the broker — a barrier on
  # the process that writes it — and the deadline is generous because the
  # failure this guards against is a slow machine, not a defect.
  defp await_subscription(server, subject, deadline \\ 2_000) do
    Enum.find_value(1..(deadline |> div(5)), fn _ ->
      subscriptions = NatsServer.subscriptions(server)

      if Enum.any?(subscriptions, &(&1.subject == subject)) do
        true
      else
        Process.sleep(5)
        false
      end
    end) || flunk("no subscription to #{subject} appeared on the broker")
  end

  # The record is written by the SUBSCRIBER process from its `handle_info/2`,
  # and the hops between `Gnat.pub/3` returning and that write are a socket,
  # the connection process and a `Process.send/2` — none of which the caller
  # can barrier on. So the wait is for the FACT to exist: the row, written on
  # the test's shared sandbox connection. That is a wait for a positive fact
  # with a deadline, not an assertion on silence, and the fact is written by
  # the process under test.
  defp await_record(id, deadline \\ 2_000) do
    Enum.find_value(1..(deadline |> div(5)), fn _ ->
      if Repo.get(ConsumedEvent, id) do
        true
      else
        Process.sleep(5)
        false
      end
    end) || flunk("no consumed_events row for #{id} appeared within #{deadline}ms")
  end

  # Exactly-one-email, drained AFTER the sends have all happened. The sends
  # run inside `Consumers.consume/0` in this test process, so the mailbox is
  # settled when it returns and the drain is a count rather than a wait — the
  # opposite of asserting on silence.
  defp drain_emails(acc \\ [])

  defp drain_emails(acc) do
    receive do
      {:email, email} -> drain_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the subscription" do
    test "is to the identity.> PREFIX, not to the subscribed types", ctx do
      await_subscription(ctx.server, "identity.>")

      subjects = Enum.map(NatsServer.subscriptions(ctx.server), & &1.subject)

      assert "identity.>" in subjects
      refute "identity.user.created" in subjects

      assert Subscriber.subject() == "identity.>"
    end

    test "with no broker there is no subscriber at all" do
      # The whole of the dark-loop refusal, on the consuming side: an empty
      # LIST rather than a child the supervisor has to remember to ignore.
      Application.put_env(:courier, :nats, url: nil)

      assert Subscriber.supervised_child() == []
    end
  end

  describe "an identity.> event reaching the bus" do
    test "produces exactly one welcome mail", ctx do
      await_subscription(ctx.server, "identity.>")

      publish("identity.user.created", Jason.encode!(envelope()))

      # The delivery is recorded before the effect is owed: the row exists
      # because the BROKER delivered, and the handler's success is what marks
      # it. That ordering is the crash-recovery property, so it is asserted
      # rather than assumed.
      await_record(envelope()["id"])

      row = Repo.get(ConsumedEvent, envelope()["id"])
      assert row
      assert row.type == "identity.user.created"
      assert row.source == "identity"
      assert row.data["email"] == "kaka@example.com"
      assert is_nil(row.consumed_at)

      # The sweep dispatches it, which is where the effect happens.
      summary = Consumers.consume()
      assert summary.handled == 1

      handled = Repo.get!(ConsumedEvent, envelope()["id"])
      assert handled.consumed_at

      # One mail, and the outbox row that proves it is one send.
      assert [email] = drain_emails()
      assert [{_name, "kaka@example.com"}] = email.to
      assert email.subject == "Welcome to caFaye"

      assert Repo.aggregate(Courier.OutboxEvent, :count, :id) == 1
    end

    test "delivered TWICE with the same event id, produces ONE mail", ctx do
      assert await_subscription(ctx.server, "identity.>")

      # The publisher crashes between publishing and marking the row, or the
      # broker redelivers after a restart — either way the same envelope id
      # arrives twice. Delivery is at-least-once; a second welcome mail is
      # indistinguishable from spam. The unique constraint is the discipline,
      # so this drives the same id through the real socket twice and asserts
      # the effect happened once.
      payload = Jason.encode!(envelope())

      publish("identity.user.created", payload)
      publish("identity.user.created", payload)

      await_record(envelope()["id"])

      rows =
        ConsumedEvent
        |> where([row], row.id == ^envelope()["id"])
        |> Repo.all()

      assert length(rows) == 1

      summary = Consumers.consume()
      assert summary.handled == 1

      # Exactly one email, drained after the sends: the second delivery
      # produced no second effect.
      assert [email] = drain_emails()
      assert [{_name, "kaka@example.com"}] = email.to

      assert Repo.aggregate(Courier.OutboxEvent, :count, :id) == 1
    end

    test "an event for a type courier does not subscribe to is RECORDED and skipped", ctx do
      await_subscription(ctx.server, "identity.>")

      # identity publishes `identity.member.removed` from the same file; the
      # handler does not exist yet. A subscription to four exact types would
      # have dropped this on the floor. The prefix records it, the loop
      # reports it skipped and leaves it claimable for the `consumes:` entry
      # added later.
      removed =
        envelope()
        |> Map.put("id", "8c9d0e1f-0000-4000-8000-00000000000b")
        |> Map.put("type", "identity.member.removed")

      publish("identity.member.removed", Jason.encode!(removed))

      await_record(removed["id"])

      assert Repo.get(ConsumedEvent, removed["id"])

      summary = Consumers.consume()
      assert summary.skipped == 1
      assert summary.handled == 0

      refute_email_sent()
    end
  end

  describe "a delivery that cannot be recorded" do
    test "is a warning naming the topic and not the payload, and the subscriber survives", ctx do
      await_subscription(ctx.server, "identity.>")

      # Bytes that are not an envelope: no id to dedupe on, nothing a handler
      # could ever act on. The refusal is loud — a warning with the topic and
      # the reason — and silent about the content, which is the redaction
      # boundary on the consuming side.
      # Both deliveries go over the ONE connection, so the two `:msg`
      # callbacks are processed in order: when the good event's row exists,
      # the bad delivery's refusal has certainly been logged. The wait for
      # that row is the barrier, inside the capture.
      log =
        capture_log(fn ->
          publish("identity.user.created", "not json at all: kaka@example.com")

          # And it keeps receiving, which is the point of not crashing: a
          # subscriber callback that raises takes the subscription down for
          # every subsequent message.
          publish("identity.user.created", Jason.encode!(envelope()))
          await_record(envelope()["id"])
        end)

      assert log =~ "identity.user.created"
      assert log =~ "could not record"
      refute log =~ "kaka@example.com"

      # The good event after the bad one still arrived.
      assert Repo.get(ConsumedEvent, envelope()["id"])
    end
  end
end
