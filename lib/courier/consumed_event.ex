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

  # `:string` and not `Ecto.UUID`, because this is the **publisher's** uuid read
  # off an envelope and courier validates nothing about its shape. An `Ecto.UUID`
  # type would cast it and raise on anything that is not exactly 36 hex
  # characters — turning a malformed event from a refusal into a crash in the
  # subscriber, which is the one failure mode this whole table exists to prevent.
  # The column is `NOT NULL` primary key either way, which is the part that
  # carries the dedupe.
  @primary_key {:id, :string, autogenerate: false}

  schema "consumed_events" do
    # The envelope's id, and the primary key — see the moduledoc.
    field :type, :string
    field :source, :string
    field :subject, :string
    field :data, :map, default: %{}

    # The order the facts happened, and what `claim/0` orders on. NOT NULL in the
    # database; a row with no time would sort to the end of every batch on
    # PostgreSQL's default for NULL, which is silently wrong rather than refused.
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
    # **The dedupe declared as a constraint, not handled as an exception.**
    # Without this line `Repo.insert/1` RAISES `Ecto.ConstraintError` on the
    # second delivery of the same envelope, because Ecto only converts a
    # constraint violation into a changeset error for constraints the changeset
    # has declared — and an at-least-once bus makes that second delivery
    # ordinary operation. So this is not error handling around an edge case; it
    # is what makes the table's one promise (`Courier.Consumers.record/2`
    # answers `{:error, :already_consumed}`) reachable at all.
    #
    # Matched on the constraint NAME rather than on the rendered message, because
    # the message is assembled by the adapter and a driver upgrade would change
    # the words.
    |> unique_constraint(:id, name: :consumed_events_pkey)
  end
end
