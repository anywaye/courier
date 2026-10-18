defmodule Courier.NotificationType do
  @moduledoc """
  A notification type courier can send, stored in the database so consumers
  can add and use types through courier's API without touching courier's code.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "notification_types" do
    field :type, :string
    field :kind, :string, default: "transactional"
    field :required, {:array, :string}, default: []
    field :subject, :string
    field :html_template, :string
    field :text_template, :string

    timestamps(type: :utc_datetime_usec)
  end

  @valid_kinds ~w(transactional bulk)
  @valid_fields ~w(user_id email name url account_name invited_by role reason previous_email amount_display invoice_id)a

  def changeset(notification_type, attrs) do
    notification_type
    |> cast(attrs, [:type, :kind, :required, :subject, :html_template, :text_template])
    |> validate_required([:type, :kind, :subject, :html_template, :text_template])
    |> validate_format(:type, ~r/^[a-z][a-z0-9_]*$/)
    |> validate_inclusion(:kind, @valid_kinds)
    |> validate_required_fields()
    |> validate_templates()
  end

  defp validate_required_fields(changeset) do
    case get_field(changeset, :required) do
      nil -> changeset
      list when is_list(list) ->
        valid = Enum.map(@valid_fields, &Atom.to_string/1)
        bad = Enum.reject(list, &(&1 in valid))
        if bad == [], do: changeset, else: add_error(changeset, :required, "unknown fields: #{Enum.join(bad, ", ")}")
      _ -> add_error(changeset, :required, "must be a list")
    end
  end

  defp validate_templates(changeset) do
    html = get_field(changeset, :html_template)
    text = get_field(changeset, :text_template)

    changeset
    |> maybe_validate_eex(:html_template, html)
    |> maybe_validate_eex(:text_template, text)
  end

  defp maybe_validate_eex(changeset, _field, nil), do: changeset
  defp maybe_validate_eex(changeset, field, src) when is_binary(src) do
    try do
      EEx.compile_string(src)
      changeset
    rescue
      e -> add_error(changeset, field, "invalid template: #{Exception.message(e)}")
    end
  end
end