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

    * the subscription is to the **per-service prefixes**, not to the four
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

    start_supervised!({Nats, []})
    start_supervised!(Subscriber)

    on_exit(fn -> Application.put_env(:courier, :nats, original) end)

    %{server: server, port: port}
  end

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

  defp publish(subject, payload) do
    {:ok, connection} = Nats.connection()
    _ = Gnat.pub(connection, subject, payload)
    :ok
  end

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

  defp drain_emails(acc \\ [])

  defp drain_emails(acc) do
    receive do
      {:email, email} -> drain_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the subscription" do
    test "is to every service PREFIX the consumers name, not to the subscribed types", ctx do
      await_subscription(ctx.server, "identity.>")
      await_subscription(ctx.server, "billing.>")

      subjects = Enum.map(NatsServer.subscriptions(ctx.server), & &1.subject)

      assert "identity.>" in subjects
      assert "billing.>" in subjects
      refute "identity.user.created" in subjects
      refute "billing.payment.succeeded" in subjects

      assert Subscriber.subjects() == ["billing.>", "identity.>"]

      services =
        Consumers.subscribed() |> Enum.map(&(&1 |> String.split(".") |> hd())) |> Enum.uniq()

      assert Subscriber.subjects() == Enum.map(Enum.sort(services), &(&1 <> ".>"))
    end

    test "with no broker there is no subscriber at all" do
      Application.put_env(:courier, :nats, url: nil)

      assert Subscriber.supervised_child() == []
    end
  end

  describe "an identity.> event reaching the bus" do
    test "produces exactly one welcome mail", ctx do
      await_subscription(ctx.server, "identity.>")

      publish("identity.user.created", Jason.encode!(envelope()))

      await_record(envelope()["id"])

      row = Repo.get(ConsumedEvent, envelope()["id"])
      assert row
      assert row.type == "identity.user.created"
      assert row.source == "identity"
      assert row.data["email"] == "kaka@example.com"
      assert is_nil(row.consumed_at)

      summary = Consumers.consume()
      assert summary.handled == 1

      handled = Repo.get!(ConsumedEvent, envelope()["id"])
      assert handled.consumed_at

      assert [email] = drain_emails()
      assert [{_name, "kaka@example.com"}] = email.to
      assert email.subject == "Welcome to Anywaye"

      assert Repo.aggregate(Courier.OutboxEvent, :count, :id) == 1
    end

    test "delivered TWICE with the same event id, produces ONE mail", ctx do
      assert await_subscription(ctx.server, "identity.>")

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

      assert [email] = drain_emails()
      assert [{_name, "kaka@example.com"}] = email.to

      assert Repo.aggregate(Courier.OutboxEvent, :count, :id) == 1
    end

    test "an event for a type courier does not subscribe to is RECORDED and skipped", ctx do
      await_subscription(ctx.server, "identity.>")

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

      log =
        capture_log(fn ->
          publish("identity.user.created", "not json at all: kaka@example.com")

          publish("identity.user.created", Jason.encode!(envelope()))
          await_record(envelope()["id"])
        end)

      assert log =~ "identity.user.created"
      assert log =~ "could not record"
      refute log =~ "kaka@example.com"

      assert Repo.get(ConsumedEvent, envelope()["id"])
    end
  end
end
