defmodule Courier.Repo.Migrations.AddProviderMessageIdToOutboxEvents do
  use Ecto.Migration

  @moduledoc """
  The provider's own message id, beside courier's — so a delivery report can be
  joined to the send it is about.

  ## The defect this column exists for

  `Courier.Deliver` mints `"courier-" <> Ecto.UUID.generate()`, writes it into
  the message's `Message-ID` header (`Courier.Deliver.tag/2`) and records it in
  `outbox_events.subject`. `Courier.InboundReports` joins a provider's bounce or
  complaint back to that send by matching the `Message-ID` the report quotes
  against `outbox_events.subject`.

  That join assumes the provider quotes **courier's** id. The Cloudflare Email
  adapter's provider does not: it owns the `Message-ID`, refuses a
  caller-supplied one, and reports its own `result.message_id`. So a real
  password reset sent through it was recorded with `subject =
  courier-2be282f1-…`, the provider's report quoted a different id, and
  `Courier.InboundReports` logged `courier holds no sent message for Message-ID
  "…"` — its suppression recorded, no event, and nothing able to say which send,
  which user, or which notification type the bounce was about.

  ## Why a column and not a change to `subject`

  `subject` is courier's own id and is load-bearing: every existing row holds
  one, `Courier.OutboxEvent.envelope/1` publishes it, and the platform's own
  events are keyed on it. Removing it to store the provider's id instead would
  break every row and every test to gain nothing this column does not. So
  courier keeps its own id and records the provider's alongside it, and the
  join in `Courier.InboundReports` matches EITHER.

  `data` is deliberately NOT the place for this. `courier.email.delivered`'s
  schema in `anywaye/core` is `additionalProperties: false` with four frozen
  fields, so a fifth key on the event would fail core's own schema on the bus.
  The provider's id is a fact for the JOIN, which reads rows, not for the
  payload.

  ## Nullable, and the absence is a real state

  The adapter may legitimately answer a 2xx with no `message_id` in the body —
  `Courier.Adapters.CloudflareEmail.accepted/2` supports that shape — and
  courier invents nothing in its place. A null here means "the provider gave
  courier no id to correlate against", and a report that quotes nothing courier
  holds still records its suppression and still says so in a log line.
  """

  def change do
    alter table(:outbox_events) do
      add :provider_message_id, :string
    end

    # The join's own lookup, and the only query that reads this column. Partial
    # because the column is null for every send whose provider gave no id, and a
    # report never quotes null; the index should cover the rows that have one.
    create index(:outbox_events, [:provider_message_id],
             where: "provider_message_id IS NOT NULL",
             name: :outbox_events_provider_message_id_idx
           )
  end
end
