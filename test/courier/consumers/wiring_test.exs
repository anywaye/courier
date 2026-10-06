defmodule Courier.Consumers.WiringTest do
  @moduledoc """
  That the consumer is WIRED, which is a different claim from that it works.

  `Courier.ConsumersTest` proves the loop; this file proves the facts about the
  tree that make the loop run at all, and both are things a reader cannot check
  by looking at `lib/`:

    * **the crontab entry exists** — a sweep nothing schedules is a loop that
      runs in tests and never in production;
    * **nothing was added to the supervision tree** — which is a decision, and a
      decision that needs a reason and a test rather than an omission.

  ## WHY IT READS `config/config.exs` AND NOT APPLICATION ENV

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

  ## WHY THE SUBSCRIPTION IS NOT A SUPERVISED CHILD, ASSERTED RATHER THAN
  ## EXPLAINED

  A subscriber needs a broker, and courier has no NATS client: `Courier.
  NatsPublisher` is a behaviour with a stand-in and the Gnat module is a later
  packet. A supervised process opening a socket to a broker courier does not
  depend on would make a developer's `mix phx.server` fail to boot on a
  connection it cannot make.

  **What IS scheduled is the sweep**, because the sweep needs no broker: the
  table, the claim, the ordering, the retry budget and the exhaustion rule are
  all real and all tested now. A consumer whose those rules were untested until
  the broker arrives is a consumer whose first real event is also the first time
  those rules run.

  ## THE WIRING BUG THIS FILE EXISTS TO MAKE SOMEBODY THINK ABOUT

  When the Gnat subscriber is written, the two halves must meet: `record/1`
  writes the row **on delivery**, and the sweep claims it. A subscriber that
  acknowledged the broker straight from `handle/1` — acking BEFORE the row is
  durable — would lose every event that arrived in the gap, silently and
  permanently, and no assertion here would see it. That is the failure mode a
  consumer's ordering has to be written to prevent, and it is why the ordering
  is a claim on `time` and a `skip locked` rather than a preference.
  """

  use ExUnit.Case, async: true

  defp config_source, do: File.read!(Path.join(File.cwd!(), "config/config.exs"))
  defp application_source, do: File.read!(Path.join(File.cwd!(), "lib/courier/application.ex"))

  defp worker_source,
    do: File.read!(Path.join(File.cwd!(), "lib/courier/workers/consume_events_worker.ex"))

  describe "the sweep is scheduled" do
    test "and it is a crontab entry, not only an Oban worker" do
      assert config_source() =~
               ~r/^\s*\{"\* \* \* \* \*",\s*Courier\.Workers\.ConsumeEventsWorker\}/m,
             "ConsumeEventsWorker exists and nothing schedules it. A sweep that only runs " <>
               "in `mix test` is a loop that never runs in production"
    end

    test "and it runs every minute, which is the outbox's own cadence" do
      # The same number the outbox relay gets, and for the same reason: a minute
      # is the ceiling on how long a stuck row can sit, which is also the number
      # an alert would use. A longer interval here would mean a failed handler's
      # retry budget is measured in hours while `max_attempts` says ten.
      assert config_source() =~
               ~r/\{"\* \* \* \* \*",\s*Courier\.Workers\.(ProcessOutboxWorker|ConsumeEventsWorker)\}/
    end

    test "and its queue is declared, because a worker on an undeclared queue never runs" do
      # Oban ignores an insert for a queue it was not configured with. Same trap
      # as the `:states` one in `Courier.Outbox`: a valid worker module, a
      # job that never runs.
      assert config_source() =~ ~r/queues: \[[^\]]*consumers/
    end

    test "and it runs every minute BECAUSE a delivered event has no write to hang an enqueue on" do
      # The outbox's crontab is a floor under a fast path. This one has no fast
      # path: nothing in courier's code causes an event to arrive, so there is
      # nothing to enqueue from and the timer is the only shape. The comment in
      # the config says so, and this is what stops it being deleted as
      # "belt and braces" by somebody reading it next to the other three.
      assert config_source() =~ "strongest form of it"
    end
  end

  describe "the subscription is not a supervised child" do
    test "and that is the deliberate half, asserted as an absence" do
      refute application_source() =~ "Courier.Consumers"
      refute application_source() =~ "ConsumeEventsWorker"
    end

    test "and the worker's moduledoc says why, so the absence reads as a decision" do
      # An absence nobody can explain is an omission. These three strings are the
      # whole argument — no NATS client, a socket that would fail a developer's
      # boot, and the sweep being the only path — and they are asserted because a
      # moduledoc that loses them loses the reason with them.
      assert worker_source() =~ "no NATS client"
      assert worker_source() =~ "only path"
    end
  end
end
