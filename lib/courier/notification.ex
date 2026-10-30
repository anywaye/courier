defmodule Courier.Notification do
  @moduledoc """
  One event, addressed to one person, with the two facts about whether they have
  looked at it.


  A row with no recipient is a fan-out that has not happened, and an inbox that
  could see one would answer "how many unread?" with a number nobody can act on.
  So `recipient_type` and `recipient_id` are both `NOT NULL` in the migration, and
  there is no way to construct one without naming somebody. The reference's
  `noticed_notifications` allows it; this does not.

  `recipient_type` names **what kind** of recipient — `"user"` today, which is a
  uuid from identity — and `recipient_id` is that person. There is **no foreign
  key**, for the reason `Courier.NotificationPreference` records for `user_id`:
  courier does not own users, there is no `users` table in this database to
  point at, and a `references/2` would be a constraint against another service's
  schema.


  * `seen_at` — "this appeared in a list". Nobody had to open anything; it was on
    screen in an inbox. This is what a badge can honestly count.
  * `read_at` — "this person opened it". A deliberate act.

  They are not the same column with two names. An unread row can be seen and not
  read — the ordinary state of something scrolled past — and a row can be neither.
  **A row that is read and not seen is not a state this service produces**, and
  the database refuses it (`check (read_at is null or seen_at is not null)`)
  rather than leaving it to `mark_read/2` to remember: the table is also written
  by a console and by migrations, and a rule three places have to hold is a rule
  two of them will not.


  Not the account. An event is addressed to people, and addressing the same
  event to the same person twice writes the same row twice — which is what makes
  an unread count wrong by one, silently, in the one number a badge shows. The
  account is the row's **owner**, not part of its identity, for the same reason
  `notification_preferences` is keyed by `(user_id, notification_type)` alone.

  `Courier.Notifications.record/2` relies on it rather than checking first, so
  two callers who both believe they were first produce one row and the loser is
  told what happened.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Courier.NotificationEvent

  @type t :: %__MODULE__{}

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "notifications" do
    field :account_id, Ecto.UUID
    field :recipient_type, :string
    field :recipient_id, :string
    field :seen_at, :utc_datetime_usec
    field :read_at, :utc_datetime_usec

    timestamps()

    belongs_to :event, NotificationEvent, foreign_key: :notification_event_id
  end

  @doc """
  The changeset for addressing one event to one recipient.

  `account_id` is **not cast** — see `Courier.NotificationEvent.changeset/2` for
  why, which is the same answer. `notification_event_id`, `recipient_type` and
  `recipient_id` are cast because they are the addressing itself and this module
  is where that is written down; `Courier.Notifications.record/2` is the only
  caller and it supplies all three.
  """
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:notification_event_id, :recipient_type, :recipient_id])
    |> validate_required([:notification_event_id, :recipient_type, :recipient_id])
    |> validate_length(:recipient_type, max: 255)
    |> validate_length(:recipient_id, max: 255)
  end

  @doc """
  Whether this person has opened it.

  `false` for a row that has merely been seen, which is the distinction the two
  timestamps exist for and the reason neither of them is a boolean.
  """
  @spec read?(t()) :: boolean()
  def read?(%__MODULE__{read_at: read_at}), do: not is_nil(read_at)

  @doc """
  Whether it has appeared in a list at all — and it is `true` for a row that has
  been read, because opening it is a stronger statement than seeing it.
  """
  @spec seen?(t()) :: boolean()
  def seen?(%__MODULE__{seen_at: seen_at, read_at: read_at}) do
    not is_nil(seen_at) or not is_nil(read_at)
  end
end
