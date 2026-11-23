defmodule Medlum.Repo.Migrations.CreateDocumentsAndIngestionPipeline do
  use Ecto.Migration

  def up do
    create table(:document_uploads, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:patient_id, references(:patients, type: :binary_id, on_delete: :nilify_all))
      add(:uploader_id, references(:users, on_delete: :nilify_all))
      add(:document_kind, :string)
      add(:filename, :string, null: false)
      add(:content_type, :string)
      add(:byte_size, :bigint)
      add(:sha256, :string)
      add(:status, :string, null: false, default: "pending")
      add(:storage_backend, :string, null: false, default: "postgres")
      add(:stored_path, :string)
      add(:raw_blob, :binary)
      add(:metadata, :map, null: false, default: %{})
      add(:ingested_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(index(:document_uploads, [:tenant_id, :status]))
    create(index(:document_uploads, [:patient_id]))
    create(unique_index(:document_uploads, [:tenant_id, :sha256], where: "sha256 IS NOT NULL"))

    create table(:document_parses, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:upload_id, references(:document_uploads, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:parser, :string, null: false)
      add(:parsed_text, :text)
      add(:structured_metadata, :map, null: false, default: %{})
      add(:extracted_at, :utc_datetime, null: false)

      add(
        :patient_profile_id,
        references(:patient_profiles, type: :binary_id, on_delete: :nilify_all)
      )

      timestamps(type: :utc_datetime)
    end

    create(index(:document_parses, [:upload_id]))

    create table(:document_chunks, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:parse_id, references(:document_parses, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:position, :integer, null: false)
      add(:content, :text, null: false)
      add(:token_count, :integer)

      timestamps(type: :utc_datetime)
    end

    create(index(:document_chunks, [:parse_id, :position], unique: true))

    create table(:ingestion_jobs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)

      add(:upload_id, references(:document_uploads, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:job_type, :string, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:attempts, :integer, null: false, default: 0)
      add(:error, :map)
      add(:metadata, :map, null: false, default: %{})
      add(:scheduled_at, :utc_datetime)
      add(:started_at, :utc_datetime)
      add(:finished_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(index(:ingestion_jobs, [:tenant_id, :status]))
    create(index(:ingestion_jobs, [:upload_id]))

    create table(:ingestion_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:job_id, references(:ingestion_jobs, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:event_type, :string, null: false)
      add(:payload, :map, null: false, default: %{})
      add(:recorded_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:ingestion_events, [:job_id]))

    execute("""
    ALTER TABLE patient_profiles
    ADD CONSTRAINT patient_profiles_parsed_from_upload_id_fkey
    FOREIGN KEY (parsed_from_upload_id)
    REFERENCES document_uploads(id)
    ON DELETE SET NULL
    """)
  end

  def down do
    execute("""
    ALTER TABLE patient_profiles
    DROP CONSTRAINT IF EXISTS patient_profiles_parsed_from_upload_id_fkey
    """)

    drop_if_exists(table(:ingestion_events))
    drop_if_exists(index(:ingestion_jobs, [:upload_id]))
    drop_if_exists(index(:ingestion_jobs, [:tenant_id, :status]))
    drop_if_exists(table(:ingestion_jobs))
    drop_if_exists(index(:document_chunks, [:parse_id, :position]))
    drop_if_exists(table(:document_chunks))
    drop_if_exists(index(:document_parses, [:upload_id]))
    drop_if_exists(table(:document_parses))
    drop_if_exists(index(:document_uploads, [:tenant_id, :status]))
    drop_if_exists(index(:document_uploads, [:patient_id]))
    drop_if_exists(index(:document_uploads, [:tenant_id, :sha256]))
    drop_if_exists(table(:document_uploads))
  end
end
