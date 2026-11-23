defmodule Medlum.Repo.Migrations.AddLastPatientIdToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:last_patient_id, references(:patients, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:users, [:last_patient_id]))
  end
end
