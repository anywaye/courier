defmodule Courier.NotificationEvent do
  @moduledoc """
  Something that happened, once, for an account — the half of a notification that
  is not about anybody in particular.

  An event is **not** a notification and storing one without the other is what
  `Courier.Notifications.record/2` exists to prevent: a row here with no
  `notifications` row naming a recipient is a fan-out that has not happened yet,
  and a recipient's unread count that could see one would be a lie.

  `type` is a closed vocabulary validated in `changeset/2` against
  `Courier.Notifications.types/0`. It is **not** `Courier.Events.types/0` and the
  two are deliberately different lists: `Courier.Events` is what courier emits on
  the bus to other services, and an in-app event is a thing a person is told
  about. `Courier.EventsTest` asserts the bus list; nothing here asserts the two
  agree, because they are not supposed to.

  `record_type` and `record_id` are a **polymorphic, optional** reference to
  whatever the event happened to — an order, a subscription, a member, or
  nothing at all. "Your trial ends tomorrow" has no record behind it. Both are
  `NOT NULL` together or `NULL` together; the changeset is what keeps that, and
  the reason there is no foreign key is that courier does not own any of those
  tables (there is no `users` table in this database) and a `references/2` would
  be a constraint against another service's schema.

  `params` is the structured payload, and it is **jsonb rather than a rendered
  string on purpose**. The reference implementation ships notification bodies as
  ERB fragments rendered through `ApplicationController.render`; courier is
  API-only and renders nothing. A consumer reads these keys and decides what a
  person sees. The keys are courier's promise and the rendering is not.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Courier.Notifications

  @type t :: %__MODULE__{}

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "notification_events" do
    field :account_id, Ecto.UUID
    field :type, :string
    field :record_type, :string
    field :record_id, :string
    field :params, :map, default: %{}

    timestamps()
  end

  @doc """
  The changeset for one event.

  `account_id` is **not cast** and is set by `Courier.Notifications.record/2` from
  the calling account. A caller cannot name it, which is the same rule
  `Courier.NotificationPreference` follows and for the same reason: the account is
  the row's owner rather than part of what it says, and a body that could set it
  would be a body that could write into somebody else's inbox.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:type, :record_type, :record_id, :params])
    |> validate_required([:type, :params])
    |> validate_type()
    |> validate_record_reference()
  end

  defp validate_type(changeset) do
    validate_change(changeset, :type, fn :type, type ->
      if type in Notifications.types(), do: [], else: [type: "is not a notification type"]
    end)
  end

  defp validate_record_reference(changeset) do
    type = get_change(changeset, :record_type)
    id = get_change(changeset, :record_id)

    cond do
      is_nil(type) and is_nil(id) ->
        changeset

      is_binary(type) and is_nil(id) ->
        Ecto.Changeset.add_error(changeset, :record_id, "is required when record_type is given")

      is_nil(type) and is_binary(id) ->
        Ecto.Changeset.add_error(changeset, :record_type, "is required when record_id is given")

      true ->
        changeset
    end
  end
end
