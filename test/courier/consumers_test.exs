defmodule Courier.ConsumersTest do
  @moduledoc """
  The consumer: subscribe, claim, handle, mark — and the decision that is the
  whole packet, which is **what the consumer marks, and when**.


  The relay marks `published_at` when the broker acknowledges. The consumer
  cannot use that rule and the reason is structural rather than a preference:

    * **The relay's mark is about the BROKER.** Nobody has acted on the message;
      an unacknowledged publish means the event may not have reached the bus at
      all, so the only safe thing is to send it again.
    * **The consumer's mark is about THE WORLD.** An acknowledged delivery means
      the handler has *already run* — the provider was dialled, the person may
      already have the mail. Marking on ack would record "handled" for a handler
      that then failed, and the next pass would skip it. **The mark has to come
      from the handler's own answer, and nothing else.**

  So `consumed_at` is written on handler success, and a handler failure leaves
  it `NULL`. That is the whole mechanism, and it inverts the relay's order on
  purpose: the relay acks *then* marks because nothing has happened yet; the
  consumer handles *then* marks because something irreversible has.


  The packet asks whether a schema change can be avoided. It cannot, and the
  reason is core's own rule rather than a preference:

  > `core/docs/event-outbox.md` §"At-least-once, so idempotent": "**Dedupe on
  > `id`.** Store the envelope `id` in a table with a unique constraint and
  > insert it in the same transaction as the handler's own work. […] an
  > in-memory 'have I seen this?' set is wrong the moment there are two replicas."

  An at-least-once bus makes duplicates **ordinary operation**, not failure: the
  publisher commits and dies before it acks; the ack is lost after the handler
  committed; the broker redelivers. A consumer that mails twice on a duplicate
  delivers a denial of service to the mailbox.

  So `consumed_events` carries the envelope `id` as its **primary key** — the
  unique constraint IS the dedupe, and it is why there is no separate "seen"
  index to keep in step with it. There is no way to be idempotent across two
  replicas without a shared row, and the alternative (a process dictionary, an
  ETS set) is correct on one replica and wrong on the second, which is the
  failure mode that never reproduces in a test.


    * **`FOR UPDATE SKIP LOCKED`**, so N replicas claim against one table and a
      slow batch in one does not stall the rest — the relay's rule, for the
      relay's reason.
    * **Oldest first**, ordered on the envelope's `time` and then the row's
      insert. Two events about one account arrive in order; two about different
      accounts do not, and a consumer that assumed global order would be wrong.
    * **A row past the attempt cap is left alone**, not retried forever and not
      dropped: a stuck event is an incident to alert on, not a mystery.
    * **A handler failure records the reason and leaves `consumed_at` NULL**,
      and the row comes back on the next pass.
    * **A malformed envelope is marked handled, and that is not a bug.** There
      is nothing to retry: a payload missing `email` will be missing `email` on
      every redelivery, forever. Refusing it loudly and moving on is the only
      behaviour that terminates. A row refused for being unreadable is
      `consumed_at`-set and carries `last_error`, because a poison message that
      retried forever is a denial of service on the subject.


  It does not crash the service. Every handler call is wrapped, a raise is
  recorded as a failure and answered `{:error, _}`, and the loop continues — a
  panic in a subscriber is a denial of service on the **whole event stream**,
  not just on the message that caused it.
  """

  use Courier.DataCase, async: false

  alias Courier.ConsumedEvent
  alias Courier.Consumers
  alias Courier.Workers.ConsumeEventsWorker

  defmodule Succeeds do
    @moduledoc false
    def handle(row), do: send(:consumer_test, {:handled, row.id}) && {:ok, %{}}
  end

  defmodule Raises do
    @moduledoc false

    def handle(row) do
      send(:consumer_test, {:reached, row.id})
      raise "the handler is broken"
    end
  end

  defmodule RefusesFirst do
    @moduledoc false

    def handle(%ConsumedEvent{id: "6a3f2b1c-0000-4000-8000-000000000001"}) do
      send(:consumer_test, {:refused, "6a3f2b1c-0000-4000-8000-000000000001"})
      {:error, :missing_acceptance_url}
    end

    def handle(row) do
      send(:consumer_test, {:handled, row.id})
      {:ok, %{}}
    end
  end

  defp envelope(attrs \\ %{}) do
    Map.merge(
      %{
        "specversion" => "1.0",
        "id" => "6a3f2b1c-0000-4000-8000-000000000001",
        "type" => "identity.member.invited",
        "source" => "identity",
        "subject" => "d1e2f3a4-5b60-4718-8a9b-0c1d2e3f4a51",
        "time" => "2026-10-06T12:00:00Z",
        "data" => %{
          "account_id" => "d1e2f3a4-5b60-4718-8a9b-0c1d2e3f4a51",
          "invitation_id" => "9c8d7e6f-1111-4222-8333-444455556666",
          "email" => "invitee@example.com",
          "role" => "member",
          "invited_by_id" => "7b6c5d4e-2222-4333-8444-555566667777"
        }
      },
      attrs
    )
  end

  defp claim_one, do: Consumers.claim()

  setup do
    original = Application.get_env(:courier, :consumers)

    on_exit(fn ->
      if original do
        Application.put_env(:courier, :consumers, original)
      else
        Application.delete_env(:courier, :consumers)
      end
    end)

    Process.register(self(), :consumer_test)

    :ok
  end

  describe "subscribed/0" do
    test "is the fleet's five, and anywaye.yml declares the same list" do
      assert Consumers.subscribed() == [
               "billing.payment.failed",
               "billing.payment.succeeded",
               "identity.member.accepted",
               "identity.member.invited",
               "identity.session.revoked",
               "identity.user.created"
             ]

      manifest = File.read!(Path.join(File.cwd!(), "anywaye.yml"))

      assert manifest =~
               ~r/^consumes:\s*$\n\s*-\s*identity\.member\.invited\s*$\n\s*-\s*identity\.member\.accepted\s*$\n\s*-\s*identity\.session\.revoked\s*$\n\s*-\s*identity\.user\.created\s*$\n\s*-\s*billing\.payment\.succeeded\s*$\n\s*-\s*billing\.payment\.failed\s*$/m
    end

    test "carries a handler for every type it subscribes to" do
      for type <- Consumers.subscribed() do
        handler = Consumers.handler_for(type)

        assert handler != nil, "#{type} is subscribed to and has no handler"

        assert Code.ensure_loaded?(handler), "#{inspect(handler)} does not exist"
        assert function_exported?(handler, :handle, 1), "#{inspect(handler)} has no handle/1"
      end
    end

    test "never names courier's own events" do
      for type <- Consumers.subscribed() do
        refute String.starts_with?(type, "courier.")
      end
    end
  end

  describe "claim/0" do
    test "claims a delivered envelope, oldest first, keyed on the envelope's own id" do
      now = DateTime.utc_now()
      {:ok, _} = Consumers.record(envelope(), inserted_at: DateTime.add(now, -60, :second))
      {:ok, _} = Consumers.record(envelope(%{"id" => "b0000000-0000-4000-8000-000000000002"}))

      assert [oldest, newest] = Consumers.claim()
      assert oldest.id == "6a3f2b1c-0000-4000-8000-000000000001"
      assert newest.id == "b0000000-0000-4000-8000-000000000002"
    end

    test "orders by the ENVELOPE's time, not the row's insert" do
      now = DateTime.utc_now()

      {:ok, _} =
        Consumers.record(
          envelope(%{
            "time" => "2026-10-06T12:00:00Z",
            "id" => "c0000000-0000-4000-8000-000000000003"
          }),
          inserted_at: now
        )

      {:ok, _} =
        Consumers.record(
          envelope(%{
            "time" => "2026-10-06T11:00:00Z",
            "id" => "c0000000-0000-4000-8000-000000000004"
          }),
          inserted_at: DateTime.add(now, -120, :second)
        )

      assert [%ConsumedEvent{id: "c0000000-0000-4000-8000-000000000004"} | _] = Consumers.claim()
    end

    test "does not claim a row already handled" do
      {:ok, _} = Consumers.record(envelope())
      [event] = claim_one()
      {:ok, _} = Consumers.mark_handled(event)

      assert Consumers.claim() == []
    end

    test "does not claim a row past the attempt cap, and leaves it readable" do
      {:ok, _} = Consumers.record(envelope())
      [event] = claim_one()

      exhaust(event, Consumers.max_attempts())

      assert Consumers.claim() == []

      row = Repo.get(ConsumedEvent, envelope()["id"])
      assert row.attempt_count == Consumers.max_attempts()
      assert is_nil(row.consumed_at)
    end

    defp exhaust(_event, 0), do: :ok

    defp exhaust(event, remaining) do
      if remaining > 1 do
        {:ok, event} = Consumers.attempt(event, "provider refused")
        [claimed] = Consumers.claim()
        exhaust(claimed, remaining - 1)
      else
        {:ok, _} = Consumers.attempt(event, "provider refused")
        :ok
      end
    end

    test "a duplicate delivery is refused by the primary key, and that is not an error" do
      assert {:ok, _} = Consumers.record(envelope())
      assert {:error, :already_consumed} = Consumers.record(envelope())
    end

    test "records the envelope's subject and type, so a row is readable without the payload" do
      {:ok, event} = Consumers.record(envelope())

      assert event.type == "identity.member.invited"
      assert event.subject == "d1e2f3a4-5b60-4718-8a9b-0c1d2e3f4a51"
      assert event.source == "identity"
      assert event.data["email"] == "invitee@example.com"
    end

    test "refuses an envelope with no id, because there is no key to dedupe it under" do
      assert {:error, :unreadable_envelope} = Consumers.record(envelope(%{"id" => nil}))
      assert {:error, :unreadable_envelope} = Consumers.record(envelope(%{"id" => ""}))
      assert {:error, :unreadable_envelope} = Consumers.record("not a map")
    end

    test "refuses a subject courier cannot order by, because ordering is the contract" do
      assert {:error, :unreadable_envelope} = Consumers.record(envelope(%{"time" => nil}))
      assert {:error, :unreadable_envelope} = Consumers.record(envelope(%{"time" => "yesterday"}))
    end
  end

  describe "mark_handled/1" do
    test "is set from the HANDLER's answer, never from the ack" do
      {:ok, _} = Consumers.record(envelope())
      [event] = claim_one()

      assert is_nil(Repo.get(ConsumedEvent, event.id).consumed_at)

      {:ok, marked} = Consumers.mark_handled(event)

      assert marked.consumed_at
      assert marked.last_error == nil
    end

    test "clears a previous failure's reason, so the row reads as what it now is" do
      {:ok, _} = Consumers.record(envelope())
      [event] = claim_one()
      {:ok, event} = Consumers.attempt(event, "provider refused")
      [event] = claim_one()

      {:ok, marked} = Consumers.mark_handled(event)

      assert marked.last_error == nil
      assert marked.attempt_count == 1
    end
  end

  describe "attempt/2" do
    test "leaves consumed_at NULL, so the next pass retries it" do
      {:ok, _} = Consumers.record(envelope())
      [event] = claim_one()

      {:ok, marked} = Consumers.attempt(event, "provider refused")

      assert is_nil(marked.consumed_at)
      assert marked.attempt_count == 1
      assert marked.last_error == "provider refused"
    end

    test "a reason too long for the column is truncated rather than crashing the loop" do
      {:ok, _} = Consumers.record(envelope())
      [event] = claim_one()

      {:ok, marked} = Consumers.attempt(event, String.duplicate("x", 10_000))

      assert String.length(marked.last_error) <= 2_000
    end
  end

  describe "consume/0" do
    test "dispatches an envelope and marks it handled" do
      {:ok, _} = Consumers.record(envelope())
      Application.put_env(:courier, :consumers, %{"identity.member.invited" => Succeeds})

      summary = Consumers.consume()

      assert_received {:handled, "6a3f2b1c-0000-4000-8000-000000000001"}
      assert summary.handled == 1
      assert summary.failed == 0
      assert Repo.get(ConsumedEvent, "6a3f2b1c-0000-4000-8000-000000000001").consumed_at
    end

    test "a handler that raises is a failed row, not a dead consumer" do
      {:ok, _} = Consumers.record(envelope())
      {:ok, _} = Consumers.record(envelope(%{"id" => "d0000000-0000-4000-8000-000000000005"}))
      Application.put_env(:courier, :consumers, %{"identity.member.invited" => Raises})

      summary = Consumers.consume()

      assert_received {:reached, "6a3f2b1c-0000-4000-8000-000000000001"}
      assert_received {:reached, "d0000000-0000-4000-8000-000000000005"}

      assert summary.handled == 0
      assert summary.failed == 2

      for id <- ["6a3f2b1c-0000-4000-8000-000000000001", "d0000000-0000-4000-8000-000000000005"] do
        row = Repo.get(ConsumedEvent, id)

        assert is_nil(row.consumed_at)
        assert row.attempt_count == 1
        assert row.last_error =~ "the handler is broken"
      end
    end

    test "one refusal does not hold up the events behind it" do
      {:ok, _} = Consumers.record(envelope())
      {:ok, _} = Consumers.record(envelope(%{"id" => "e0000000-0000-4000-8000-000000000006"}))
      Application.put_env(:courier, :consumers, %{"identity.member.invited" => RefusesFirst})

      summary = Consumers.consume()

      assert_received {:refused, "6a3f2b1c-0000-4000-8000-000000000001"}
      assert_received {:handled, "e0000000-0000-4000-8000-000000000006"}
      assert summary.handled == 1
      assert summary.failed == 1
    end

    test "an event courier does not subscribe to is neither handled nor failed" do
      {:ok, _} = Consumers.record(envelope(%{"type" => "billing.payment.failed"}))
      Application.put_env(:courier, :consumers, %{"identity.member.invited" => Succeeds})

      summary = Consumers.consume()

      refute_received {:handled, _}
      assert summary.handled == 0
      assert summary.failed == 0

      row = Repo.get(ConsumedEvent, "6a3f2b1c-0000-4000-8000-000000000001")
      assert row.attempt_count == 0
      assert is_nil(row.last_error)
    end

    test "the summary names the first reason, so one log line says why" do
      {:ok, _} = Consumers.record(envelope())
      Application.put_env(:courier, :consumers, %{"identity.member.invited" => RefusesFirst})

      summary = Consumers.consume()

      assert summary.reason == :missing_acceptance_url
    end
  end

  describe "the crontab sweep" do
    test "an empty queue is `{:ok, summary}` and not an error" do
      assert {:ok, summary} = ConsumeEventsWorker.perform(%Oban.Job{})
      assert summary == %{handled: 0, skipped: 0}
    end

    test "a failed handler is an error, so Oban retries and the row stays claimable" do
      {:ok, _} = Consumers.record(envelope())
      Application.put_env(:courier, :consumers, %{"identity.member.invited" => RefusesFirst})

      assert {:error, summary} = ConsumeEventsWorker.perform(%Oban.Job{})
      assert summary.failed == 1
    end

    test "the backoff is capped, jittered, and grows with the attempt" do
      waits =
        for attempt <- 1..8 do
          ConsumeEventsWorker.backoff(%Oban.Job{attempt: attempt})
        end

      assert Enum.all?(waits, &(is_integer(&1) and &1 > 0))
      assert Enum.min(waits) < Enum.max(waits)
      assert Enum.max(waits) <= 60
    end
  end

  describe "the whole member-invited path, wired together" do
    test "a delivered invitation event reaches the handler and is recorded" do
      {:ok, _} = Consumers.record(envelope())

      summary = Consumers.consume()

      assert summary.failed == 1
      assert summary.reason == :missing_acceptance_url

      row = Repo.get(ConsumedEvent, "6a3f2b1c-0000-4000-8000-000000000001")
      assert row.type == "identity.member.invited"
      assert is_nil(row.consumed_at)
      assert row.attempt_count == 1
    end
  end
end
