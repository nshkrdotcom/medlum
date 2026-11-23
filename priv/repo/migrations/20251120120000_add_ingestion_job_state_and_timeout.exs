defmodule Medlum.Repo.Migrations.AddIngestionJobStateAndTimeout do
  use Ecto.Migration

  def up do
    alter table(:ingestion_jobs) do
      add(:state, :string, null: false, default: "pending")
      add(:timeout_at, :utc_datetime)
      add(:last_error, :text)
    end

    create(index(:ingestion_jobs, [:state]))

    execute("""
    UPDATE ingestion_jobs
    SET state = CASE
      WHEN stage IN ('completed', 'failed') THEN stage
      WHEN stage = 'queued' THEN 'queued'
      WHEN stage IN ('downloading', 'docling', 'parsing') THEN 'running'
      WHEN status = 'processing' THEN 'running'
      WHEN status = 'completed' THEN 'completed'
      WHEN status = 'failed' THEN 'failed'
      WHEN status = 'queued' THEN 'queued'
      ELSE COALESCE(status, 'pending')
    END
    """)
  end

  def down do
    drop_if_exists(index(:ingestion_jobs, [:state]))

    alter table(:ingestion_jobs) do
      remove(:state)
      remove(:timeout_at)
      remove(:last_error)
    end
  end
end
