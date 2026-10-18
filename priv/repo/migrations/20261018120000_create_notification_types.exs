defmodule Courier.Repo.Migrations.CreateNotificationTypes do
  use Ecto.Migration

  def up do
    create table(:notification_types, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false
      add :kind, :string, null: false, default: "transactional"
      add :required, :jsonb, null: false, default: "[]"
      add :subject, :string, null: false
      add :html_template, :text, null: false
      add :text_template, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:notification_types, [:type])

    execute("grant select, insert, update, delete on notification_types to courier_app")
  end

  def down do
    drop table(:notification_types)
  end
end