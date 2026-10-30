defmodule Courier.ConsumedEvent do
  @moduledoc """
  One row per event courier has **received**, keyed on the envelope's own id.

  The counterpart to `Courier.OutboxEvent`, and the two are not mirrors of each
  other — that difference is the design:

    * `outbox_events` is written by courier and marked when the **broker**
      acknowledges. Nobody has acted on the message yet, so an unacknowledged
      publish can safely be repeated.
    * `consumed_events` is written on **delivery** and marked when the
      **handler** succeeds. The provider has already been dialled by then, so a
      repeat is a second email to a person.

  So the columns are three separate facts and nothing derives one from another:

  | column          | the fact                                         |
  | --------------- | ------------------------------------------------ |
  | `attempt_count` | this has been tried N times                       |
  | `last_error`    | the most recent failure's reason, or `NULL`       |
  | `consumed_at`   | **the handler succeeded**, and only that          |

  `id` is the envelope's own id rather than a generated one, and that is the
  dedupe rather than a convenience: the primary key IS the unique constraint
  core's at-least-once rule asks for, so a redelivery cannot insert and
  `Courier.Consumers.record/2` answers `{:error, :already_consumed}`.
  See `priv/repo/migrations/20261006140000_create_consumed_events.exs`.

  **There is no `account_id`, and that is the same posture `outbox_events`
  takes.** A consumed event is courier's own bookkeeping about a message from
  another service; the account is in the payload and stays there. courier reads
  these rows on a background sweep with no principal, so a policy keyed on
  `current_account_id()` would filter out every row the consumer exists to read.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}

  schema "consumed_events" do
    field :type, :string
    field :source, :string
    field :subject, :string
    field :data, :map, default: %{}

    field :time, :utc_datetime_usec

    field :consumed_at, :utc_datetime_usec
    field :attempt_count, :integer, default: 0
    field :last_error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The changeset for one delivered envelope.

  **`id` is `put_change`d and never `cast`.** Cast is what would let a caller's
  map decide the primary key, and the primary key here *is* the dedupe: a caller
  that supplied its own id would insert a second row for one delivery and the
  handler would run twice for a single event. `Courier.Consumers.record/2` reads
  it off the envelope itself, having already refused an envelope with none —
  because an envelope with no id has nothing to be idempotent *on*, and a row
  without one would be silently unrepeatable rather than refused.
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:type, :source, :subject, :data, :time])
    |> validate_required([:type, :source, :data, :time])
    |> put_change(:id, attrs[:id])
    |> unique_constraint(:id, name: :consumed_events_pkey)
  end
end
