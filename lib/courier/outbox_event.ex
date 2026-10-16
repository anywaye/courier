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

    # The provider's own id for this send, when the adapter's receipt carried
    # one. `subject` stays courier's id — it is what the platform's events are
    # keyed on — and this is the SECOND id, recorded so a provider's bounce or
    # delivery report, which quotes the provider's id and not courier's, can be
    # joined to the send it is about. Null is a real state: a 2xx with no
    # `message_id` in the body records nothing here and courier invents none.
    # See `Courier.InboundReports.with_data/2` for the join.
    field :provider_message_id, :string

    field :published_at, :utc_datetime_usec
    field :attempt_count, :integer, default: 0
    field :last_error, :string

    # The two columns courier added for the webhook fan-out. `account_id` is
    # whose endpoints this event goes to and is nullable because `Courier.Deliver`
    # records a send for a *user*, and courier does not know which account that
    # user is in. `webhooks_dispatched_at` is when the event was fanned out, which
    # is a different moment from `published_at`: an event can be on the bus and
    # not yet fanned out.
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

  # `account_id` is optional and set here rather than cast. It is the account the
  # event is fanned out to, and an event courier emitted itself (`email.delivered`
  # for a person, not a tenant) has none — which is a valid state, not a
  # validation error, and a row with none is skipped by the fan-out rather than
  # delivered to every account that happens to exist.
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
