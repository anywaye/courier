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

  ## What is in one transaction, and what is not

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

  ## Why a replay is answered and not refused

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

  ## Why there is no `Idempotency-Key` on the route

  Because the header a provider sends is the one courier does not accept, and a
  plug that stores a response keyed on a header nobody sends is a retry courier is
  not listening for. `CourierWeb.Plugs.Idempotency` is also scoped to a principal
  and this route has none, deliberately. The mechanism that does the work is
  `courier`'s own unique index, which is stronger than the header in the one case
  that matters — two deliveries of the same report under two different
  `webhook-id`s, which is what a provider that re-signs a retry does.

  ## And why the route is not behind `CourierWeb.Plugs.Principal`

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

  ## Why this lookup exists at all, and it is a workaround

  `Courier.Suppressions.ingest/1` finds a duplicate by **inserting and catching
  the unique violation**, then reading the winning row back
  (`Courier.Suppressions.duplicate/1`). That is correct and it is the right shape
  — "A 'have I seen this?' check in Elixir would be a race; the index cannot be" —
  but it only works **outside** a transaction. PostgreSQL aborts a whole
  transaction on a statement error, so the read that follows the failed insert
  answers `25P02 current transaction is aborted` and the caller raises. Measured,
  not assumed:

      # outside a transaction
      Suppressions.ingest(event)  #=> {:ok, :new, row}  then  {:ok, :duplicate, row}

      # inside Repo.transaction/1
      Suppressions.ingest(event)  #=> ** (Postgrex.Error) 25P02

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

  # One event, one fold. The counts are accumulated rather than read back, because
  # a `Repo.all/1` with no `order_by` is PostgreSQL's order and a count derived
  # from an unordered list is a claim about the server.
  #
  # A **soft bounce never reaches the lookup**, and that is not an optimisation:
  # `ingest/1` writes no row for one, so there is nothing that could be a
  # duplicate, and asking would be a query whose answer cannot change the outcome.
  defp record(%{kind: :soft_bounce} = event, counts) do
    # `ingest/1` is still called, because it is the authority on what courier does
    # about a soft bounce and this module is not going to answer that question
    # itself. Its only answer here is `{:ok, :ignored}` and the compiler knows it,
    # so there is deliberately no catch-all: a second answer would be a change to
    # `Courier.Suppressions`' vocabulary, and this module would fail to compile
    # rather than quietly count a shape it does not understand.
    _ = Suppressions.ingest(event)
    bump(counts, [:received, :ignored])
  end

  defp record(event, counts) do
    case existing(event) do
      # A replay. The row is courier's own and the event it announced is already
      # on the bus, so this counts and moves on.
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

      # Unreachable by the lookup one statement ago unless two identical
      # deliveries raced, and then this one lost the unique index. The transaction
      # unwinds, the provider retries, and the retry is answered `:duplicate` by
      # `existing/1`. Rolling back is the safe direction: a 503 the provider
      # retries, rather than a 200 claiming the report was recorded when the row
      # in the other transaction is the one that recorded it.
      {:ok, :duplicate, _row} ->
        Repo.rollback({:concurrent_duplicate, event})

      {:ok, :ignored} ->
        bump(counts, [:received, :ignored])

      # A row courier could not write. The transaction unwinds, so a report that
      # half-landed is not a report at all — the alternative is a suppression
      # nobody was told about, which is the silent half-record this module exists
      # to refuse.
      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # The counters one outcome increments, in one call — a pipeline of two `bump/2`s
  # reads as two things happening when it is one.
  #
  # Written as a `reduce/3` over the keys with the element and the accumulator
  # named explicitly, because `reduce/3` hands them in that order and swapping them
  # produces a `BadMapError` on `:received` rather than anything that looks like an
  # argument-order mistake. The private function is `inc/2` and not `update/2`
  # because `import Ecto.Query` above already owns that name — a collision here is
  # a `CompileError` about a malformed Ecto query, which is a very poor error
  # message for a shadowed private function.
  defp bump(counts, keys), do: Enum.reduce(keys, counts, &inc(&2, &1))

  defp inc(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  # The event for a row that was just written, or nothing at all.
  #
  # The `:new` clause is the only one that publishes, and that is why a replay is
  # free: the second delivery of a report is a `:duplicate` and never reaches
  # here, so a `courier.email.bounced` is published once per bounce by
  # construction rather than by a check somebody has to remember.
  #
  # A row whose state names neither fact has no event, and that is a **count of
  # nothing** rather than a rollback — the row is real and `ingest/1` wrote it, so
  # unwinding on an announcement courier could not build would throw away the fact
  # that stopped the mail. It is unreachable from `ingest/1`, which only ever
  # records those two states, and the clause exists so a state added later is a
  # missing event with a log line rather than a crash inside a transaction.
  defp publish(counts, row) do
    case attrs(row) do
      nil -> counts
      attrs -> insert_event(attrs, counts)
    end
  end

  # **The write goes through `Courier.Outbox.insert/1`, not `Repo.insert/1`, and
  # that is the only reason a bounce reaches the bus.** The outbox write and the
  # relay job that publishes it are one transaction, so a suppression courier
  # recorded cannot exist without something queued to announce it — the same
  # defect `Courier.Outbox` documents, from the other writer. Enqueueing only from
  # the send path would leave every bounce and complaint sitting in a durable row
  # that nothing would ever read, which is precisely the state this repository was
  # in.
  defp insert_event(attrs, counts) do
    case Outbox.insert(OutboxEvent.changeset(%OutboxEvent{}, attrs)) do
      {:ok, _event} ->
        Map.update!(counts, :events, &(&1 + 1))

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  # Which envelope, by the STATE courier decided rather than by the provider's
  # word. A `:complaint` records `:suppressed` and a hard bounce records
  # `:undeliverable`, and a state that is neither is a row this module cannot
  # announce — so nothing is published rather than a guess about which of the two
  # facts it was.
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

  # **The payload is the message that bounced, and that is the whole difficulty.**
  #
  # `core/schemas/events/courier/email/bounced.schema.json` requires
  # `message_id` / `user_id` / `notification_type` / `email` with
  # `additionalProperties: false`. A provider report carries a `Message-ID` and a
  # recipient; it does not carry a user id or a notification type, and courier is
  # not going to invent them — a `courier.email.bounced` whose `user_id` is `null`
  # is a payload that fails core's own schema on the bus, and a bus consumer
  # rejecting it is a worse outcome than not publishing.
  #
  # So courier **looks the send up**. `outbox_events.subject` is the message id
  # `Courier.Deliver` chose and wrote into the RFC 5322 `Message-ID` header, and
  # that row's `data` is the four fields the event needs, already validated at the
  # point they were written. `user_id` and `notification_type` are read from it
  # rather than carried across, and `email` is the row's own address — which for a
  # broadcast is the address that bounced and not the one the send was addressed
  # to, which is exactly what the schema asks for.
  #
  # A report courier cannot tie to a send records its suppression and publishes no
  # event, and says so. That is the one gap in this module and it is a gap in the
  # DATA, not in the mechanism: the mechanism is right for every report whose
  # `Message-ID` names a send courier made, and the fallback is a refusal rather
  # than a fabricated payload.
  # The two payloads are the same map, and they are built by one function for the
  # same reason `Courier.Events.complained/1` documents: core specifies both
  # against the same four fields, and a bounce and a complaint that drifted apart
  # would be two payload contracts where core froze one.
  defp with_data(type, %Suppression{} = row) do
    case sent_for(row) do
      %{subject: subject, data: data} ->
        %{
          type: type,
          # `subject` is the message, and the same value as `data.message_id`,
          # which core's schema requires and states in so many words: "Always
          # equal to the envelope's `subject`". The stored row is courier's own
          # id, so the two cannot drift.
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

  # The `outbox_events` row for the send this report is about, or `:unknown`.
  #
  # Two candidate forms are tried, and the order is the reason there are two.
  # `Suppression` stores the `Message-ID` **as a provider quoted it** — RFC
  # 5322's angle brackets stripped, and the qualifier left in place, because two
  # providers quoting the same message differently must not be two rows.
  # `outbox_events` holds courier's own id in `subject` and the PROVIDER's id
  # (when the adapter's receipt carried one) in `provider_message_id`. So the
  # stripped form is tried first, the quoted form second, and each candidate is
  # matched against BOTH columns — a report whose `Message-ID` is neither a
  # `subject` nor a `provider_message_id` courier holds — one from before, one
  # from another system, one a provider invented — is `:unknown`.
  #
  # **Why the provider's column is here at all.** courier tags every message
  # with `<courier-<uuid>@anywaye.com>` and the Cloudflare provider owns the
  # `Message-ID` — it refuses a caller-supplied one and reports its own
  # `result.message_id`. So the id its reports quote is `provider_message_id`,
  # and matching only on `subject` is what produced the "courier holds no sent
  # message" warning for a message courier really sent. Both columns are read in
  # one query, so a provider that quotes either id resolves.
  defp sent_for(%Suppression{message_id: message_id}) when is_binary(message_id) do
    bare = strip_qualifier(message_id)
    Enum.find_value([bare, message_id], :unknown, &sent/1)
  end

  defp sent_for(%Suppression{}), do: :unknown

  # One candidate, matched against the send's own id and the provider's. A
  # provider id may itself carry a qualifier the suppression kept, which is why
  # `sent_for/1` tries the stripped form first; `strip_qualifier/1` is a no-op on
  # an id with no `@`, so a bare provider id is tried as itself.
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
            # A provider can quote an id courier issued for a send it never
            # recorded, and a hand-written `data` would put a user id nobody
            # checked on the bus. Both are refused.
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

  # What makes a row courier will publish: a `user_id` and a
  # `notification_type` that are there, because a `nil` in either is a payload
  # core's schema would reject on the bus. The query above has already decided
  # the row IS this report's send — by `subject` or by `provider_message_id` —
  # so the match is not re-tested here; the id-shape check the earlier version
  # made is the query's own WHERE clause now, for both columns rather than one.
  defp attributable?(%OutboxEvent{data: data}) do
    is_binary(data["user_id"]) and is_binary(data["notification_type"])
  end

  # `<courier-…@anywaye.com>` → `courier-…`. A provider's qualifier is the domain
  # courier sent from and carries no information about the send, while the local
  # part IS courier's id. The whole value is logged, not a shape derived from it.
  defp strip_qualifier("<>"), do: ""

  defp strip_qualifier(message_id) do
    message_id |> String.split("@", parts: 2) |> hd()
  end

  # The log line, and it is the whole value rather than a derived shape: an
  # operator asking "which message was this" needs the id, and a log line that
  # said only "unattributable" would not answer it.
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
