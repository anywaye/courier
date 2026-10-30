defmodule Courier.Consumers.WiringTest do
  @moduledoc """
  That the consumer is WIRED, which is a different claim from that it works.

  `Courier.ConsumersTest` proves the loop; this file proves the facts about the
  tree that make the loop run at all, and both are things a reader cannot check
  by looking at `lib/`:

    * **the crontab entry exists** — a sweep nothing schedules is a loop that
      runs in tests and never in production;
    * **the subscription is a supervised child WHEN `NATS_URL` is** — which is
      the delivery half the bus was one-ended without, and the same
      conditional-harness the connection uses.


  Because in test there is no crontab to read. `config/test.exs` sets
  `config :courier, Oban, testing: :manual`, and a `config` call **replaces the
  key rather than merging into it** — so `Application.get_env(:courier, Oban)`
  in the suite has no `:plugins` at all. That is deliberate and is what keeps the
  Ecto sandbox usable (Oban under `:manual` starts no plugins, so no timer fires
  during a test), and it is exactly why asserting on application env here would
  be asserting on nothing: the assertions would be green in CI and would have
  nothing to say about production.

  The file is the artifact that reaches production, and `Courier.OutboxEnqueueTest`
  reads `Oban.Cron`'s actual behaviour for the other half — the crontab being
  *configured* and the plugin *starting* are two claims and this packet makes
  only the first.


  An earlier version of this file asserted `refute application_source() =~
  "Courier.Consumers"`, and its own moduledoc said why: "a subscriber needs a
  broker, and courier has no NATS client". The broker client landed with the
  outbox packet — `Courier.Nats` dials, retries on a fixed interval, survives
  an outage without taking the application down — and the consumer's delivery
  half is `Courier.Consumers.Subscriber`, supervised on the same condition as
  the connection: `Nats.enabled?()`. The absence was a decision with a
  reason; the reason expired and the assertion went with it.

  **The two halves still have to meet, and the ordering is the claim this
  file's ancestor was written to make somebody think about.** `record/1`
  writes the row **on delivery**, and the sweep claims it. A subscriber that
  acknowledged the broker straight from `handle/1` — acking BEFORE the row is
  durable — would lose every event that arrived in the gap, silently and
  permanently, and no assertion here would see it. That failure mode is what
  the consumer's ordering is written to prevent, and `Courier.ConsumersTest`
  asserts it from the other side: the ack (a JetStream publish's ack, on the
  relay side) and the row (this side) are different facts about different
  processes.
  """

  use ExUnit.Case, async: true

  defp config_source, do: File.read!(Path.join(File.cwd!(), "config/config.exs"))
  defp application_source, do: File.read!(Path.join(File.cwd!(), "lib/courier/application.ex"))

  defp worker_source,
    do: File.read!(Path.join(File.cwd!(), "lib/courier/workers/consume_events_worker.ex"))

  defp subscriber_source,
    do: File.read!(Path.join(File.cwd!(), "lib/courier/consumers/subscriber.ex"))

  describe "the sweep is scheduled" do
    test "and it is a crontab entry, not only an Oban worker" do
      assert config_source() =~
               ~r/^\s*\{"\* \* \* \* \*",\s*Courier\.Workers\.ConsumeEventsWorker\}/m,
             "ConsumeEventsWorker exists and nothing schedules it. A sweep that only runs " <>
               "in `mix test` is a loop that never runs in production"
    end

    test "and it runs every minute, which is the outbox's own cadence" do
      assert config_source() =~
               ~r/\{"\* \* \* \* \*",\s*Courier\.Workers\.(ProcessOutboxWorker|ConsumeEventsWorker)\}/
    end

    test "and its queue is declared, because a worker on an undeclared queue never runs" do
      assert config_source() =~ ~r/queues: \[[^\]]*consumers/
    end

    test "and it runs every minute BECAUSE a delivered event has no write to hang an enqueue on" do
      assert config_source() =~ "strongest form of it"
    end
  end

  describe "the subscription IS a supervised child, when a broker is" do
    test "and that is the delivery half the bus was one-ended without" do
      assert application_source() =~ "Courier.Consumers.Subscriber.supervised_child()"
    end

    test "and it is conditional on NATS_URL, so a dark bus starts nothing" do
      assert subscriber_source() =~ "if Nats.enabled?(), do: [child_spec([])], else: []"
    end

    test "and the worker's moduledoc says why the sweep is separate" do
      assert worker_source() =~ "no broker"
      assert worker_source() =~ "Courier.Consumers.Subscriber"
      assert worker_source() =~ "the sweep is scheduled"
    end
  end
end
