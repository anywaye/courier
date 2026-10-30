defmodule Courier.OutboxEvent do
  @moduledoc """
  One row per emission, written in the same transaction as the send that caused
  it — the whole point of the outbox (`core/docs/event-outbox.md`): a mail that
  went out is a row the platform can see, and a row the platform cannot see did
  not go out.

  The `id` is the envelope's `id`, generated before the insert and reused on
  every republish, so a consumer that deduplicates on `id` actually dedupes.

  `published_at` is the only definition of published — not "attempted", not
  "handed to a client" — and it is set from the publisher's acknowledgement, in
  `Courier.Workers.ProcessOutboxWorker`, never here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Courier.Events

  @source "courier"

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "outbox_events" do
    field :type, :string
    field :source, :string
    field :subject, :string
    field :occurred_at, :utc_datetime_usec
    field :data, :map

    field :provider_message_id, :string

    field :published_at, :utc_datetime_usec
    field :attempt_count, :integer, default: 0
    field :last_error, :string

    field :account_id, Ecto.UUID
    field :webhooks_dispatched_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The changeset for one emission.

  The `id` is generated here, before the insert, and `occurred_at` defaults to
  now — the time the state change happened, not the time the row was published,
  which is core's rule and the reason a row that sat unpublished for an hour
  still reports the original time.

  `provider_message_id` is cast and optional: the provider's own id for the send,
  recorded beside courier's (`:subject`) so a report that quotes the provider's
  id can be joined back to the send. See the field's comment and
  `Courier.InboundReports`.
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:type, :subject, :data, :provider_message_id])
    |> validate_required([:type, :subject, :data])
    |> put_change(:id, Ecto.UUID.generate())
    |> put_change(:source, @source)
    |> put_change(:occurred_at, DateTime.utc_now())
    |> put_account(attrs)
  end

  defp put_account(changeset, attrs) do
    case Map.get(attrs, :account_id) || Map.get(attrs, "account_id") do
      nil -> changeset
      account_id -> put_change(changeset, :account_id, account_id)
    end
  end

  @doc """
  The CloudEvents envelope this row publishes as.

  Built from the stored columns, so the message a consumer receives is the row
  courier recorded rather than a re-rendering of the payload that could drift
  from it — including the `id` and the `time`, which is what makes a republish
  of this row the same event and not a new one.
  """
  @spec envelope(t()) :: map()
  def envelope(%__MODULE__{} = event) do
    Events.envelope(%{
      id: event.id,
      type: event.type,
      source: event.source,
      subject: event.subject,
      time: event.occurred_at,
      data: event.data
    })
  end
end
