defmodule Courier.Repo.Migrations.AddApplicationKeyToTenantSendingDomains do
  use Ecto.Migration

  def change do
    alter table(:tenant_sending_domains) do
      add :application_key, :string
    end

    create index(:tenant_sending_domains, [:application_key])
  end
end
