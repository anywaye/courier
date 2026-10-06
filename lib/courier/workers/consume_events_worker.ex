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

  Because a subscriber needs a broker. courier has no NATS client yet —
  `Courier.NatsPublisher` is a behaviour with a stand-in and the Gnat module is
  a later packet — and starting a process that opens a socket to a broker courier
  does not depend on would make a dev `mix phx.server` fail to boot on a
  connection it cannot make.

  What IS wired is the sweep, because the sweep needs no broker: the table and
  the loop are real, and the delivery path that fills the table is the one thing
  that waits. A consumer whose retry budget, ordering and exhaustion rules are
  untested until the broker lands is a consumer whose first real event is also
  the first time those rules run.

  `test/courier/consumers/not_wired_test.exs` asserts the crontab entry is
  present and the supervision tree is unchanged, because "the sweep exists" is
  a comment and "the sweep is scheduled" is a fact somebody can read out of
  `config/config.exs`.
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
