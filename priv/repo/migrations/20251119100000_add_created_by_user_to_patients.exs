defmodule Medlum.Repo.Migrations.AddCreatedByUserToPatients do
  use Ecto.Migration

  def change do
    alter table(:patients) do
      add(:created_by_user_id, references(:users, on_delete: :nilify_all))
    end

    create(index(:patients, [:created_by_user_id]))
  end
end
