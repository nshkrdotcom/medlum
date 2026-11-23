defmodule Medlum.Repo.Migrations.CreateTenantsAndDomains do
  use Ecto.Migration

  @default_tenant_id Ecto.UUID.generate()

  def up do
    create table(:tenants, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:status, :string, null: false, default: "active")
      add(:primary_domain, :string)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:tenants, [:slug]))
    create(index(:tenants, [:status]))

    create table(:tenant_domains) do
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:host, :string)
      add(:email_domain, :string)
      add(:primary, :boolean, default: false, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:tenant_domains, [:tenant_id, :host], where: "host IS NOT NULL"))

    create(
      unique_index(:tenant_domains, [:tenant_id, :email_domain],
        where: "email_domain IS NOT NULL"
      )
    )

    create table(:tenant_settings) do
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:data, :map, null: false, default: %{})
      add(:effective_at, :utc_datetime, null: false)
      add(:superseded_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(index(:tenant_settings, [:tenant_id, :effective_at]))

    create(
      unique_index(:tenant_settings, [:tenant_id],
        where: "superseded_at IS NULL",
        name: :tenant_settings_unique_active
      )
    )

    create table(:user_memberships) do
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:role, :string, null: false, default: "guest")
      add(:default_scope, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:user_memberships, [:tenant_id, :user_id]))

    execute("""
    INSERT INTO tenants (id, name, slug, status, primary_domain, metadata, inserted_at, updated_at)
    VALUES ('#{@default_tenant_id}', 'Medlum Clinical', 'medlum-clinical', 'active', 'medlum.test', '{}', NOW(), NOW())
    ON CONFLICT (id) DO NOTHING
    """)

    alter table(:users) do
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :restrict),
        null: false,
        default: @default_tenant_id
      )

      add(:locale, :string, size: 10)
      add(:timezone, :string)
    end

    execute("UPDATE users SET tenant_id = '#{@default_tenant_id}' WHERE tenant_id IS NULL")

    create(index(:users, [:tenant_id]))

    alter table(:invitations) do
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :restrict),
        null: false,
        default: @default_tenant_id
      )
    end

    execute("UPDATE invitations SET tenant_id = '#{@default_tenant_id}' WHERE tenant_id IS NULL")
    create(index(:invitations, [:tenant_id]))
  end

  def down do
    drop(index(:invitations, [:tenant_id]))

    alter table(:invitations) do
      remove(:tenant_id)
    end

    drop(index(:users, [:tenant_id]))

    alter table(:users) do
      remove(:timezone)
      remove(:locale)
      remove(:tenant_id)
    end

    execute("DELETE FROM tenants WHERE id = '#{@default_tenant_id}'")

    drop(table(:user_memberships))
    drop(index(:tenant_settings, name: :tenant_settings_unique_active))
    drop(table(:tenant_settings))
    drop(table(:tenant_domains))
    drop(table(:tenants))
  end
end
