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

  # **A POLYMORPHIC REFERENCE IS TWO HALVES AND THE HALVES TRAVEL TOGETHER.**
  #
  # `record_type = "Order"` with no `record_id` names an order courier cannot
  # find, and a consumer rendering that row produces a link that 404s — so the
  # pair is validated here rather than by a CHECK constraint, because the
  # constraint and the changeset would be the same rule written twice, and two
  # copies of one rule can only disagree by somebody remembering to update one.
  #
  # **`add_error/4` rather than returning the error list, and this was a real
  # bug rather than a style.** The first draft returned the keyword list the
  # `case` produced, which is the shape `validate_change/3` expects from *its*
  # function and not the shape `changeset/2` returns from *this* one — so
  # `changeset/2` answered with a **list**, and
  # `Courier.Notifications.insert_event/2` piped that straight into
  # `Ecto.Changeset.put_change/3`, which would have raised on the first
  # `record_type`/`record_id` that reached this clause.
  #
  # **The type checker caught it before a test did**, which is the claim worth
  # keeping: `mix compile --warnings-as-errors` reported
  #
  #     expected one of: %Ecto.Changeset{data: map(), types: map()}, term(), term()
  #     where "attrs" was given the types:
  #       dynamic(%{..., __struct__: not_set()})
  #
  # It names the shape and not the cause, so it is not a pleasant error — but a
  # test asserting `{:error, {:event, changeset}}` for a bad `type` would have
  # failed first, and the **valid** path (no record at all) would not have
  # reached this clause on a record-carrying test until somebody wrote one. The
  # checker refused to compile a shape that could not work.
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
