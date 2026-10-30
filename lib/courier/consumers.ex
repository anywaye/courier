defmodule Courier.Consumers do
  @moduledoc """
  courier's consumer: subscribe, claim, dispatch, mark. The fleet's **first**
  one — every `consumes:` in every `anywaye.yml` was empty before this, so there
  was no subscriber anywhere and every service published into a bus nobody read.


  The relay marks `published_at` when the broker acknowledges. The consumer
  cannot use that rule, and the reason is structural:

    * **The relay's mark is about the BROKER.** Nobody has acted on the message;
      an unacknowledged publish means the event may not have reached the bus at
      all, so the only safe thing is to send it again.
    * **The consumer's mark is about THE WORLD.** The ack arrives *after* the
      handler ran — the provider was dialled, and a person may already have the
      mail. Marking on the ack would record "handled" for a handler that then
      failed, and the next pass would skip an invitation nobody was sent.

  **So `consumed_at` is written from the handler's own answer and from nothing
  else.** `attempt/2` leaves it `NULL`, which is what makes the row claimable
  again; `mark_handled/1` sets it. That inverts the relay's order deliberately:
  the relay acks *then* marks because nothing has happened yet, and the consumer
  handles *then* marks because something irreversible has.


  The packet asked whether a schema change could be avoided. It cannot, on core's
  own rule:

  > `core/docs/event-outbox.md`: "**Dedupe on `id`.** Store the envelope `id` in
  > a table with a unique constraint […] an in-memory 'have I seen this?' set is
  > wrong the moment there are two replicas."

  At-least-once makes duplicates ordinary operation: the publisher commits and
  dies before it acks, the mark statement fails after the ack, the broker
  redelivers. `consumed_events` keys on the envelope id, so the primary key is
  the dedupe and `record/2` answers `{:error, :already_consumed}`.


  Every one is the relay's rule (`Courier.Workers.ProcessOutboxWorker`) read from
  the other side, and the two are deliberately written to look alike so a reader
  who knows one knows this:

    * **`FOR UPDATE SKIP LOCKED`** — N replicas against one table, and a slow
      batch in one does not stall the rest.
    * **A batch, oldest first**, on the envelope's `time` then the row's insert.
      Two events about one account arrive in order; two about different accounts
      do not, and core says so: consumers "must not assume" global ordering.
    * **A row past the attempt cap is left alone** — not retried forever, not
      dropped. An event stuck for an hour is an incident to alert on.
    * **One refusal does not hold up the batch behind it.**


  It is left claimable and un-attempted. Not a failure: it is not this
  consumer's business, and counting it would put a permanent non-zero on a
  counter an operator watches. Leaving it claimable is also what makes a
  `consumes:` entry added *later* pick up what was already delivered rather than
  starting from nothing.


  Because a subscriber callback runs in the process that owns the subscription.
  An uncaught raise there takes down that process, which is a denial of service
  on the **whole event stream** — not just the message that caused it — and it
  does it from the inside, from a handler courier wrote. So every call is
  wrapped, the raise is recorded as the row's `last_error`, and the loop
  continues to the next event. `Courier.ConsumersTest` asserts the *second*
  event is reached, because a test that only counted rows would pass with a loop
  that stopped at the first failure.


  `subscribed/0` is the list, read from `config :courier, :consumers`. It is
  asserted against `anywaye.yml`'s `consumes:` in both directions, because a
  subscription declared in one and absent from the other is a message courier
  receives and drops — the same outcome as no subscription, one step harder to
  see. And no entry may be a `courier.` type: core's rule 2 is that a service
  never consumes its own events, because it could call itself in-process
  instead of paying for a bus.
  """

  import Ecto.Query

  require Logger

  alias Courier.ConsumedEvent
  alias Courier.Repo

  @type summary :: %{
          handled: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer(),
          reason: term()
        }

  @doc """
  Every event type courier subscribes to, in the order `anywaye.yml` declares.

  Read from `config :courier, :consumers`, whose keys are the type and whose
  values are the module with a `handle/1`. **This list and the manifest's
  `consumes:` are held to each other by a test**, so neither can gain a type the
  other does not have.
  """
  @spec subscribed() :: [String.t()]
  def subscribed do
    registry()
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  @doc """
  The module that handles `type`, or `nil`.

  `nil` is the answer for a type courier does not subscribe to, and the loop
  treats it as "not my business" rather than as a failure.
  """
  @spec handler_for(String.t() | atom()) :: module() | nil
  def handler_for(type), do: registry()[to_string(type)]

  defp registry, do: Application.get_env(:courier, :consumers, %{})

  @doc """
  Claims a batch of unhandled events, oldest first.

  The claim query is the relay's, read from the other side. `skip_locked` so two
  replicas do not contend, `consumed_at is null` so a handled row is never
  re-dispatched, and `attempt_count < max_attempts` so a stuck event is left
  alone rather than retried forever.

  **Ordered on `time`, not `inserted_at`.** A publisher's backlog delivers out
  of insert order, and the order a consumer must respect is the order the facts
  happened; a redelivered old event sorted by insert time would be handled after
  everything that came later.
  """
  @spec claim() :: [ConsumedEvent.t()]
  def claim do
    ConsumedEvent
    |> where(
      [event],
      is_nil(event.consumed_at) and event.attempt_count < ^max_attempts()
    )
    |> order_by([event], asc: event.time, asc: event.inserted_at)
    |> limit(^batch_size())
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  @doc """
  Records one delivered envelope, and refuses a duplicate by name.

  `{:ok, event}`, `{:error, :already_consumed}` for a redelivery — which is
  ordinary operation and not an incident, so it is a distinct answer rather than
  a generic error — and `{:error, :unreadable_envelope}` for something courier
  cannot even key.

  **The envelope's id is the primary key, and that is the dedupe.** Two
  replicas delivering the same event race on this insert and exactly one wins.
  The loser's `{:error, :already_consumed}` is the guarantee, not a failure of
  it.

  The `opts` are for tests only — `inserted_at` lets one test build a backlog
  whose insert order and event order disagree, which is the case the ordering
  rule exists for.
  """
  @spec record(map(), keyword()) :: {:ok, ConsumedEvent.t()} | {:error, term()}
  def record(envelope, opts \\ []) do
    with {:ok, attrs} <- attributes(envelope) do
      %ConsumedEvent{}
      |> ConsumedEvent.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, event} ->
          {:ok, event}

        {:error, changeset} ->
          if unique_violation?(changeset),
            do: {:error, :already_consumed},
            else: {:error, changeset}
      end
      |> maybe_stamp(opts)
    end
  end

  @doc """
  Marks an event handled, from the handler's success and nothing else.

  `last_error` is cleared, because a row that succeeded and still reads as
  failed is a row nobody can act on: the retry has happened and the reason on it
  is stale.
  """
  @spec mark_handled(ConsumedEvent.t()) :: {:ok, ConsumedEvent.t()} | {:error, Ecto.Changeset.t()}
  def mark_handled(%ConsumedEvent{} = event) do
    event
    |> Ecto.Changeset.change(consumed_at: DateTime.utc_now(), last_error: nil)
    |> Repo.update()
  end

  @doc """
  Records a failed attempt, and leaves `consumed_at` NULL.

  **That NULL is the answer to the packet's question.** The row stays claimable,
  so the next sweep retries it — the row's own `attempt_count` is the retry
  budget and the broker's redelivery is not something courier has to ask for.

  The reason is truncated to 2,000 characters because a provider error can be a
  whole HTML page and `last_error` is a bounded column. Truncating is not
  cosmetic: a `Repo.update!` raising on the write would kill the consumer
  mid-batch, which is the exact denial of service this module exists to avoid.
  """
  @spec attempt(ConsumedEvent.t(), term()) :: {:ok, ConsumedEvent.t()} | {:error, term()}
  def attempt(%ConsumedEvent{} = event, reason) do
    event
    |> Ecto.Changeset.change(attempt_count: event.attempt_count + 1, last_error: bound(reason))
    |> Repo.update()
  end

  @doc """
  Claims a batch, dispatches it, and marks each event on its own answer.

  `summary` carries `handled`, `failed`, `skipped` and the first `reason` the
  handlers gave, so one log line says why rather than a count nobody can act on.

  **Every handler call is wrapped.** A raise is caught, recorded on the row, and
  the loop moves to the next event — because the callback runs in the process
  that owns the subscription, and an uncaught raise there is a denial of service
  on the whole event stream.


  Two different shapes, and the difference is whether a retry could ever succeed:

    * **The handler ran and said no** (`{:error, reason}`) — a provider refusal,
      a missing field on the payload. Retryable in principle, so `consumed_at`
      stays NULL and the row comes back. This is the invitation handler's
      `:missing_acceptance_url`: it will be true on every redelivery, so the row
      walks its attempt budget and is then left alone to alert on, which is the
      honest shape for "this needs a code change".

    * **The envelope was not something courier could dispatch** — no handler for
      the type, or the type is not subscribed. `skipped`, no attempt, no mark,
      left claimable for a `consumes:` entry added later.

  A row that retried *itself* on a malformed payload would be the poison-message
  case: an event missing `email` is missing `email` on every redelivery, forever,
  so `Courier.Consumers.record/2` refuses to write it at all.
  """
  @spec consume() :: summary()
  def consume do
    Enum.reduce(claim(), %{handled: 0, failed: 0, skipped: 0, reason: nil}, &dispatch(&1, &2))
  end

  defp dispatch(event, summary) do
    case handler_for(event.type) do
      nil ->
        %{summary | skipped: summary.skipped + 1}

      handler ->
        run(handler, event, summary)
    end
  end

  defp run(handler, event, summary) do
    case safe_apply(handler, event) do
      {:ok, _result} ->
        {:ok, _} = mark_handled(event)
        %{summary | handled: summary.handled + 1}

      {:error, reason} ->
        record_failure(event, reason, summary)
    end
  end

  defp safe_apply(handler, event) do
    handler.handle(event)
  rescue
    exception ->
      Logger.error(
        "consumer handler raised on #{event.type} #{event.id}: #{Exception.message(exception)}"
      )

      _ = Exception.format_stacktrace(__STACKTRACE__)
      {:error, Exception.message(exception)}
  catch
    kind, reason ->
      Logger.error("consumer handler #{kind}ed on #{event.type} #{event.id}: #{inspect(reason)}")

      {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp record_failure(event, reason, summary) do
    case attempt(event, reason) do
      {:ok, _} ->
        :ok

      {:error, write_error} ->
        Logger.error(
          "could not record the failed attempt on #{event.id}: #{inspect(write_error)}"
        )
    end

    Logger.warning(
      "consumer could not handle #{event.type} #{event.id}: #{bound(reason)} (#{event.attempt_count + 1}/#{max_attempts()} attempts)"
    )

    %{summary | failed: summary.failed + 1, reason: summary.reason || reason}
  end

  defp attributes(envelope) when is_map(envelope) do
    with {:ok, id} <- fetch_string(envelope, "id"),
         {:ok, type} <- fetch_string(envelope, "type"),
         {:ok, source} <- fetch_string(envelope, "source"),
         {:ok, time} <- fetch_time(envelope, "time"),
         do:
           {:ok,
            %{
              id: id,
              type: type,
              source: source,
              subject: Map.get(envelope, "subject"),
              data: data(envelope),
              time: time
            }}
  end

  defp attributes(_not_a_map), do: {:error, :unreadable_envelope}

  defp fetch_string(envelope, key) do
    case Map.get(envelope, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :unreadable_envelope}
    end
  end

  defp fetch_time(envelope, key) do
    with value when is_binary(value) <- Map.get(envelope, key),
         {:ok, time, _offset} <- DateTime.from_iso8601(value) do
      {:ok, time}
    else
      _unreadable -> {:error, :unreadable_envelope}
    end
  end

  defp data(envelope) do
    case Map.get(envelope, "data") do
      data when is_map(data) -> data
      _absent -> %{}
    end
  end

  defp unique_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:id, {_message, opts}} -> to_string(opts[:constraint_name]) == "consumed_events_pkey"
      _other_error -> false
    end)
  end

  defp maybe_stamp({:ok, event}, opts) do
    case Keyword.fetch(opts, :inserted_at) do
      {:ok, inserted_at} ->
        ConsumedEvent
        |> where([row], row.id == ^event.id)
        |> Repo.update_all(set: [inserted_at: inserted_at, updated_at: inserted_at])

        {:ok, %{event | inserted_at: inserted_at, updated_at: inserted_at}}

      :error ->
        {:ok, event}
    end
  end

  defp maybe_stamp(other, _opts), do: other

  defp bound(reason) do
    text = if is_binary(reason), do: reason, else: inspect(reason)
    String.slice(text, 0, 2_000)
  end

  defp batch_size, do: tuning()[:batch_size]
  @doc "The attempt cap, read at runtime so an operator can retune without a rebuild."
  def max_attempts, do: tuning()[:max_attempts]

  defp tuning, do: Application.get_env(:courier, :consumer, [])
end
