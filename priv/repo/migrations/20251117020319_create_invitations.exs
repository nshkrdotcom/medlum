defmodule Lumainus.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  def change do
    create table(:invitations) do
      add(:token, :string, null: false)
      add(:role, :string, null: false)
      add(:email, :string)
      add(:used_at, :utc_datetime)
      add(:created_by_id, references(:users, on_delete: :nilify_all))

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:invitations, [:token]))
    create(index(:invitations, [:role]))
    create(index(:invitations, [:created_by_id]))
  end
end
