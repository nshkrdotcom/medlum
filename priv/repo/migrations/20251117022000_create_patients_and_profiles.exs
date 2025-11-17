defmodule Lumainus.Repo.Migrations.CreatePatientsAndProfiles do
  use Ecto.Migration

  def change do
    create table(:patients, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:patient_key, :string, null: false)
      add(:status, :string, null: false, default: "active")

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:patients, [:tenant_id, :patient_key]))
    create(index(:patients, [:tenant_id, :status]))

    create table(:patient_profiles, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:patient_id, references(:patients, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:given_name, :string)
      add(:family_name, :string)
      add(:mrn, :string)
      add(:date_of_birth, :date)
      add(:sex, :string)
      add(:parsed_from_upload_id, :binary_id)
      add(:effective_at, :utc_datetime, null: false)
      add(:superseded_at, :utc_datetime)
      add(:structured_metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:patient_profiles, [:patient_id, :effective_at]))
    create(index(:patient_profiles, [:parsed_from_upload_id]))

    alter table(:patients) do
      add(
        :current_profile_id,
        references(:patient_profiles, type: :binary_id, on_delete: :nilify_all)
      )
    end

    create table(:patient_notes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:patient_id, references(:patients, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:author_user_id, references(:users, on_delete: :nilify_all))
      add(:body, :text, null: false)
      add(:visibility, :string, null: false, default: "private")

      timestamps(type: :utc_datetime)
    end

    create(index(:patient_notes, [:patient_id]))
  end
end
