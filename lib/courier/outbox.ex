defmodule Courier.Outbox do
  @moduledoc """
  courier's outbox WRITE, and the only place one happens.

  `Courier.OutboxEvent` is the row. This module is what makes a row the
  beginning of a publication rather than a fact nobody reads: it inserts the row
  and, in the same transaction, queues the job that publishes it. Every writer
  goes through `insert/1` — `Courier.Deliver` and `Courier.InboundReports` today,
  and the next one tomorrow — so "a row was written and nothing will publish it"
  cannot be reached by forgetting a line at a call site.


  Because that is what closes the window, and the window is the whole argument.
  The outbox exists so that "the state changed and nobody was told" is impossible
  (`core/docs/event-outbox.md`), and a relay that is enqueued *after* the
  transaction commits reintroduces it from the other side: the process dies
  between the COMMIT and the insert and the row is unpublished forever, with
  nothing in the database saying so. One transaction means the row and its job
  commit or neither does, and the only surviving failure is a row nobody wrote.

  What this does **not** claim is that a transaction is forever. It cannot be:
  a roll back, an operator, a future call site and a restored backup all write
  rows this transaction knows nothing about. That is what `config/config.exs`'s
  crontab is for — one sweep a minute over the same table the fast path uses. The
  two overlap harmlessly because the relay's own claim excludes anything already
  published (`Courier.Workers.ProcessOutboxWorker`), which is at-least-once's
  ordinary condition rather than a second design.


  `unique: [period: :infinity, keys: [:event_id], states: :incomplete]` reads as
  "one pending relay job per event, ever", which is the invariant. Two properties
  make it the right key rather than a decorative one:

    * **`fields: [:worker]` was measured and rejected.** One key for the whole
      worker means one advisory lock for the whole worker — Oban takes
      `pg_advisory_xact_lock` around a unique insert
      (`deps/oban/lib/oban/engines/basic.ex:450`) and an xact lock is held until
      the transaction ends, so every concurrent send would serialise on one lock
      for the length of the provider's dial. It also queues one job and strands
      every send past the first until the next sweep.
    * **`states: :incomplete`, not the default.** The default holds the key for a
      job that *succeeded*, which is a row Oban has already deleted
      (`jobs: :delete`). Only the states that mean "this event is still waiting"
      belong in the constraint — and the value is the bare group, because a list
      around it is passed through to PostgreSQL as the literal state
      `"incomplete"` and refused by the `oban_job_state` enum. Measured: 22P02.

  The event id travels in the job's args even though the relay ignores its args —
  it claims a batch from the table rather than one event per job, because that is
  what core's loop asks for. So the args are the key and nothing else, and the
  worker's `perform/1` ignoring them is correct rather than an oversight.


  `insert/1` logs an `{:error, _}` kick and returns the row. The provider has
  already accepted the mail by the time this runs, so refusing the send because
  the queue was briefly unwritable would buy nothing and cost a duplicate
  delivery to a person; the row is durable and the sweep is the floor. A
  `conflict?: true` is not even an error — it is the invariant holding, and
  `test/courier/outbox_enqueue_test.exs` asserts the second kick's answer.
  """

  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.Workers.ProcessOutboxWorker

  require Logger

  @unique [period: :infinity, keys: [:event_id], states: :incomplete]

  @doc """
  Writes one outbox row and queues the relay for it, in the caller's transaction.

  `{:ok, event}` or `{:error, changeset}`, exactly as `Repo.insert/1` answers, so
  a caller that rolls back on a bad row keeps doing what it did.
  """
  @spec insert(Ecto.Changeset.t()) :: {:ok, OutboxEvent.t()} | {:error, Ecto.Changeset.t()}
  def insert(%Ecto.Changeset{} = changeset) do
    case Repo.insert(changeset) do
      {:ok, event} ->
        enqueue_relay(event.id)

        {:ok, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Queues the relay for one event, idempotently.

  `{:ok, job}` either way, and the job's `conflict?` says which: `false` when
  this call queued it, `true` when one was already waiting for that event. It is
  public because the invariant it carries belongs to the relay rather than to any
  one caller: a second producer, a repair, or an operator kicking a stuck event
  all go through here, and all of them get the same answer.

  **An `{:error, reason}` is logged by `insert/1` and is not a failed send.**
  Anything else would fail a mail the provider had already accepted.
  """
  @spec enqueue_relay(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_relay(event_id) when is_binary(event_id) do
    ProcessOutboxWorker.new(%{event_id: event_id}, unique: @unique)
    |> Oban.insert()
    |> tap(fn
      {:error, reason} ->
        Logger.error(
          "could not queue the outbox relay: #{inspect(reason)}. The row is written and " <>
            "the crontab will publish it within a minute."
        )

      {:ok, _job} ->
        :ok
    end)
  end
end
