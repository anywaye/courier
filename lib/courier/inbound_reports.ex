defmodule Courier.InboundReports do
  @moduledoc """
  One provider report, recorded, and the event that announces it.

  `Courier.Inbound.handle/5` verifies a request, parses it, and calls
  `Courier.Suppressions.ingest/1` for every event. That is the whole library
  path and it is right for a caller with no HTTP surface. A route is not that
  caller: it has to know **which** of the three refusals it is answering, because
  the three are 401, 422 and 500 and a provider reacts to each differently. So
  the route calls the two steps itself, in the order `handle/5` documents, and
  this module owns everything after them.


  The suppression row and its event are written together, and both roll back
  together, because a row without its event is a fact the platform never hears
  about and an event without its row is a claim about a mailbox courier does not
  hold. The exception is deliberate and stated: **an event courier cannot build
  commits nothing away.** A report whose `Message-ID` is not one courier issued
  still records its suppression — that is the load-bearing half, and the address
  is not going to be mailed again whatever courier can say about which message it
  was — and the missing event is a log line instead of a rollback that would
  throw the row away with it.

  The soft bounce is the third outcome and it writes nothing at all:
  `{:ok, :ignored}`, a shape the caller has to be able to tell from a row that
  was written. `Courier.Suppressions` explains why: a caller that counted
  `:ignored` as a failure would retry forever, and one that counted it as `:new`
  would be counting a row that does not exist.


  A provider delivering the same report twice is **normal**: delivery is
  at-least-once, and `Courier.Suppressions`'s unique index on
  `(provider, provider_event_id)` is what makes a redelivery harmless. So the
  second delivery is a 200 saying `duplicates: 1`, not a 409 — a provider retrying
  a report courier already holds has done nothing wrong, and a non-2xx would send
  it round the retry loop the index just spared it.

  **The key is the report's own content, not the `webhook-id` header**, and that
  is a choice rather than an accident. Spec §Verifying signatures says "use the
  `webhook-id` header as an idempotency key", and courier does not, because one
  delivery can name **many** recipients: a broadcast carries a single `webhook-id`
  and a `to` of every address it reached, and keying on the header would collapse
  them into one report and record **one** suppression for addresses that all
  bounced. `Courier.Inbound.Resend` builds the key from the type, the provider's
  email id and the address, so a retry of one report is one row per address and a
  retry of a broadcast is still one row per address.


  Because the header a provider sends is the one courier does not accept, and a
  plug that stores a response keyed on a header nobody sends is a retry courier is
  not listening for. `CourierWeb.Plugs.Idempotency` is also scoped to a principal
  and this route has none, deliberately. The mechanism that does the work is
  `courier`'s own unique index, which is stronger than the header in the one case
  that matters — two deliveries of the same report under two different
  `webhook-id`s, which is what a provider that re-signs a retry does.


  Because a provider is not a tenant. Resend signs with Svix and sends no bearer
  token, so a principal would 401 every delivery; and the alternative — behind no
  plug at all — is an unauthenticated `POST` that records suppressions, which is a
  denial of service on the whole product delivered by the feature meant to prevent
  it. Core's conventions settle it: "Inbound webhooks are not JWT-authenticated:
  they are signed, per the sender's convention, and the receiver checks the
  signature before parsing."
  """

  import Ecto.Query

  alias Courier.Events
  alias Courier.Outbox
  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.Suppression
  alias Courier.Suppressions

  require Logger

  @doc """
  The row courier already holds for this exact report, or `nil`.


  `Courier.Suppressions.ingest/1` finds a duplicate by **inserting and catching
  the unique violation**, then reading the winning row back
  (`Courier.Suppressions.duplicate/1`). That is correct and it is the right shape
  — "A 'have I seen this?' check in Elixir would be a race; the index cannot be" —
  but it only works **outside** a transaction. PostgreSQL aborts a whole
  transaction on a statement error, so the read that follows the failed insert
  answers `25P02 current transaction is aborted` and the caller raises. Measured,
  not assumed:

      Suppressions.ingest(event)

      Suppressions.ingest(event)

  A savepoint does not rescue it, and neither does rolling the savepoint back:
  the error is raised from inside `duplicate/1`'s `Repo.one/1`, before either
  could run. So a caller that needs suppression and event to be atomic — which is
  this module, and is the outbox's whole point — cannot reach the duplicate
  answer through `ingest/1` at all.

  So the replay is answered by **asking first**, and the unique index is still
  what makes it safe: the lookup can only ever be *wrong* in the direction of
  thinking a report is new, and the insert that follows then loses the index and
  the caller gets `{:error, changeset}` and rolls the whole transaction back. The
  provider's retry arrives, the lookup finds the row the winner wrote, and the
  retry is answered `:duplicate`. So the index is the arbiter exactly as
  `Courier.Suppressions` says it is, and the only cost of asking first is that a
  genuinely concurrent pair of identical deliveries costs one extra retry.

  **The honest alternative was a savepoint per event and it does not work**, which
  is the whole reason this is a lookup and not a nested transaction.
  """
  @spec existing(Suppressions.event()) :: Suppression.t() | nil
  def existing(%{provider: provider, provider_event_id: provider_event_id})
      when is_binary(provider) and is_binary(provider_event_id) do
    Suppression
    |> where(
      [s],
      s.provider == ^provider and s.provider_event_id == ^provider_event_id
    )
    |> limit(1)
    |> Repo.one()
  end

  def existing(_not_an_event), do: nil

  @typedoc """
  What one request did, and the shape `CourierWeb.InboundController` sends.

  Not an accident of implementation: the three outcomes `ingest/1` can have are
  three different facts, and a provider that retried on the wrong one of them
  would either retry forever or give up on a report courier had recorded.
  """
  @type counts :: %{
          received: non_neg_integer(),
          recorded: non_neg_integer(),
          duplicates: non_neg_integer(),
          ignored: non_neg_integer(),
          events: non_neg_integer()
        }

  @doc """
  Records every event from one verified request, and publishes what follows.

  `events` is `Courier.Inbound`'s `event/0` list — the output of
  `provider.parse/1` — and each one is handed to `Courier.Suppressions.ingest/1`
  in a single transaction with the `outbox_events` row it implies.

  Returns `{:ok, counts}`, or `{:error, changeset}` when a row could not be
  written, in which case **nothing** was written: the transaction rolled back, so
  there is no suppression with no event and no event with no suppression.

  A `:duplicate` and an `:ignored` are not errors, and neither publishes an event.
  A duplicate is a report courier already holds, and republishing its event would
  put a second `courier.email.bounced` on the bus for one bounce; a soft bounce
  records nothing, so it has no row whose `Message-ID` an event could quote.
  """
  @spec record_all([map()]) :: {:ok, counts()} | {:error, Ecto.Changeset.t()}
  def record_all(events) when is_list(events) do
    case Repo.transaction(fn -> Enum.reduce(events, empty_counts(), &record/2) end) do
      {:ok, counts} -> {:ok, counts}
      {:error, reason} -> {:error, reason}
    end
  end

  defp empty_counts do
    %{received: 0, recorded: 0, duplicates: 0, ignored: 0, events: 0}
  end

  defp record(%{kind: :soft_bounce} = event, counts) do
    _ = Suppressions.ingest(event)
    bump(counts, [:received, :ignored])
  end

  defp record(event, counts) do
    case existing(event) do
      %Suppression{} ->
        bump(counts, [:received, :duplicates])

      nil ->
        insert(event, counts)
    end
  end

  defp insert(event, counts) do
    case Suppressions.ingest(event) do
      {:ok, :new, row} ->
        counts
        |> bump([:received, :recorded])
        |> publish(row)

      {:ok, :duplicate, _row} ->
        Repo.rollback({:concurrent_duplicate, event})

      {:ok, :ignored} ->
        bump(counts, [:received, :ignored])

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp bump(counts, keys), do: Enum.reduce(keys, counts, &inc(&2, &1))

  defp inc(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  defp publish(counts, row) do
    case attrs(row) do
      nil -> counts
      attrs -> insert_event(attrs, counts)
    end
  end

  defp insert_event(attrs, counts) do
    case Outbox.insert(OutboxEvent.changeset(%OutboxEvent{}, attrs)) do
      {:ok, _event} ->
        Map.update!(counts, :events, &(&1 + 1))

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp attrs(%Suppression{state: :undeliverable} = row) do
    with_data(Events.bounced_type(), row)
  end

  defp attrs(%Suppression{state: :suppressed} = row) do
    with_data(Events.complained_type(), row)
  end

  defp attrs(%Suppression{state: other}) do
    Logger.warning(
      "recorded a suppression with no event: state #{inspect(other)} names neither a " <>
        "bounce nor a complaint, so courier has nothing to announce"
    )

    nil
  end

  defp with_data(type, %Suppression{} = row) do
    case sent_for(row) do
      %{subject: subject, data: data} ->
        %{
          type: type,
          subject: subject,
          data: %{
            "message_id" => subject,
            "user_id" => data["user_id"],
            "notification_type" => data["notification_type"],
            "email" => row.email
          }
        }

      :unknown ->
        unattributable(row, type)
        nil
    end
  end

  defp sent_for(%Suppression{message_id: message_id}) when is_binary(message_id) do
    bare = strip_qualifier(message_id)
    Enum.find_value([bare, message_id], :unknown, &sent/1)
  end

  defp sent_for(%Suppression{}), do: :unknown

  defp sent(candidate) do
    case candidate do
      "" ->
        nil

      _other ->
        query =
          from event in OutboxEvent,
            where:
              event.type == ^Events.delivered_type() and
                (event.subject == ^candidate or event.provider_message_id == ^candidate),
            order_by: [asc: event.inserted_at, asc: event.id],
            limit: 1

        case Repo.one(query) do
          %OutboxEvent{} = event ->
            if attributable?(event) do
              event
            else
              unattributable(candidate, Events.delivered_type())
              nil
            end

          nil ->
            nil
        end
    end
  end

  defp attributable?(%OutboxEvent{data: data}) do
    is_binary(data["user_id"]) and is_binary(data["notification_type"])
  end

  defp strip_qualifier("<>"), do: ""

  defp strip_qualifier(message_id) do
    message_id |> String.split("@", parts: 2) |> hd()
  end

  defp unattributable(row_or_id, type) do
    id = if is_struct(row_or_id), do: row_or_id.message_id, else: row_or_id
    email = if is_struct(row_or_id), do: row_or_id.email, else: nil

    Logger.warning(
      "recorded a #{type} with no event: courier holds no sent message for " <>
        "Message-ID #{inspect(id)} (address #{inspect(email)}), so it cannot name the " <>
        "user the message was for. The suppression is recorded; no event is published."
    )
  end
end
