defmodule Lumainus.Repo.Migrations.AddRecordSetsAndDocling do
  use Ecto.Migration

  def up do
    Oban.Migrations.up()

    create table(:patient_record_sets, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(:patient_id, references(:patients, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:label, :string, null: false)
      add(:status, :string, null: false, default: "active")
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:patient_record_sets, [:tenant_id]))
    create(index(:patient_record_sets, [:patient_id]))

    alter table(:document_uploads) do
      add(
        :record_set_id,
        references(:patient_record_sets, type: :binary_id, on_delete: :nilify_all)
      )
    end

    create(index(:document_uploads, [:record_set_id]))

    alter table(:ingestion_jobs) do
      add(
        :record_set_id,
        references(:patient_record_sets, type: :binary_id, on_delete: :nilify_all)
      )
    end

    create(index(:ingestion_jobs, [:record_set_id]))

    alter table(:report_runs) do
      add(
        :record_set_id,
        references(:patient_record_sets, type: :binary_id, on_delete: :nilify_all)
      )
    end

    create(index(:report_runs, [:record_set_id]))

    alter table(:reports) do
      add(
        :record_set_id,
        references(:patient_record_sets, type: :binary_id, on_delete: :nilify_all)
      )
    end

    create(index(:reports, [:record_set_id]))

    create table(:docling_health_checks, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:status, :string, null: false)
      add(:details, :map, null: false, default: %{})
      add(:responded_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(index(:docling_health_checks, [:status]))
    create(index(:docling_health_checks, [:inserted_at]))
  end

  def down do
    drop_if_exists(index(:docling_health_checks, [:inserted_at]))
    drop_if_exists(index(:docling_health_checks, [:status]))
    drop_if_exists(table(:docling_health_checks))

    drop_if_exists(index(:reports, [:record_set_id]))

    alter table(:reports) do
      remove(:record_set_id)
    end

    drop_if_exists(index(:report_runs, [:record_set_id]))

    alter table(:report_runs) do
      remove(:record_set_id)
    end

    drop_if_exists(index(:ingestion_jobs, [:record_set_id]))

    alter table(:ingestion_jobs) do
      remove(:record_set_id)
    end

    drop_if_exists(index(:document_uploads, [:record_set_id]))

    alter table(:document_uploads) do
      remove(:record_set_id)
    end

    drop_if_exists(index(:patient_record_sets, [:patient_id]))
    drop_if_exists(index(:patient_record_sets, [:tenant_id]))
    drop_if_exists(table(:patient_record_sets))

    Oban.Migrations.down()
  end
end
