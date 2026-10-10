defmodule Courier.Workers.ConsumeEventsWorker do
  @moduledoc """
  The sweep that drives the consumer: the fleet's first inbound worker.

  The outbox relay is enqueued by the write that produced the row, because that
  write is a moment courier can hang a job on. **A delivered event is not.**
  Nothing in courier's own code caused it, and there is no write to enqueue
  from — which is the same argument `config/config.exs` makes for
  `DeliverWebhookWorker`'s crontab entry, and for the same reason: *this is not
  a belt-and-braces second path, it is the only path.*

  So the loop runs on a timer and claims from `consumed_events`, whose rows are
  written by the subscriber on delivery. Two things reach the same table, which
  is the same overlap the outbox has between its enqueue and its crontab, and it
  is harmless for the same reason: the claim excludes anything already handled.

  ## WHY THIS IS NOT WIRED INTO THE SUPERVISION TREE

  Because a sweep needs no broker and no subscription: it reads a table and
  dispatches. What fills the table is `Courier.Consumers.Subscriber`, the
  process that holds the `identity.>` subscription and records each delivery —
  and THAT is the child in the tree, added after the broker client landed
  (`Courier.Nats`, `Courier.NatsPublisher.Bus`, in the outbox packet). The
  earlier version of this paragraph said "courier has no NATS client", and
  that stopped being true when the publish side shipped; what is true now is
  the same division, with both halves present.

  What IS wired is the sweep, and it stays wired with or without a broker:
  the table, the claim, the ordering, the retry budget and the exhaustion rule
  are all real whether or not `NATS_URL` is set. A consumer whose retry
  budget, ordering and exhaustion rules are untested until the broker lands
  is a consumer whose first real event is also the first time those rules
  run — and with the subscriber wired, the FIRST REAL EVENT on this bus is
  now also the first time the whole path runs, which is the packet's proof
  (`Courier.Consumers.SubscriberTest`) rather than its risk.

  `test/courier/consumers/wiring_test.exs` asserts the crontab entry, the
  queue and the conditional subscriber child, because "the sweep exists" is
  a comment and "the sweep is scheduled, and the subscription is supervised
  WHEN a broker is configured" is a fact somebody can read out of the tree.
  """

  alias Courier.Consumers

  @backoff_cap 60

  # Read at compile time because Oban reads a worker's options when it builds the
  # job, and `claim/0` reads the same key at runtime — the relay's arrangement,
  # kept so the two agree on what "past the cap" means.
  @max_attempts Application.compile_env(:courier, :consumer)[:max_attempts]

  # `use` BEFORE `backoff/1`, or Oban's own default `backoff/1` is defined first
  # and this clause is reported as a clause that can never match. The relay's
  # ordering is the same for the same reason, and it is worth a line because
  # `--warnings-as-errors` turns this into a red build rather than a note.
  use Oban.Worker, queue: :consumers, max_attempts: @max_attempts

  # The relay's backoff ceiling in seconds, for the relay's reason: a minute is
  # short enough that a broker that comes back is picked up while anyone is still
  # watching, and long enough that an outage is not a hot loop.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    base =
      attempt
      |> max(1)
      |> min(8)
      |> Kernel.-(1)
      |> then(&(2 ** &1))

    min(@backoff_cap, base + :rand.uniform(base))
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    summary = Consumers.consume()

    if summary.failed == 0 do
      {:ok, Map.take(summary, [:handled, :skipped])}
    else
      # An error, so Oban's backoff applies and the unhandled rows stay claimable.
      # A sweep that always answered `{:ok, _}` would report success while
      # invitations sat unsent — the same "a command that exits zero" failure
      # this repository's gate exists to catch.
      {:error, Map.take(summary, [:handled, :failed, :skipped, :reason])}
    end
  end
end
