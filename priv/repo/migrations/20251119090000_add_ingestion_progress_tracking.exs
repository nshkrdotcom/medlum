defmodule Lumainus.Repo.Migrations.AddIngestionProgressTracking do
  use Ecto.Migration

  def up do
    alter table(:ingestion_jobs) do
      add(:stage, :string, null: false, default: "queued")
      add(:progress, :integer, null: false, default: 0)
      add(:last_message, :text)
    end

    alter table(:ingestion_events) do
      add(:progress, :integer)
      add(:message, :text)
    end

    create(index(:ingestion_jobs, [:stage]))

    execute("""
    UPDATE ingestion_jobs
    SET stage = COALESCE(status, 'queued'),
        progress = CASE
          WHEN status IN ('completed', 'failed') THEN 100
          WHEN status = 'processing' THEN 50
          WHEN status = 'queued' THEN 10
          ELSE 0
        END
    """)
  end

  def down do
    drop_if_exists(index(:ingestion_jobs, [:stage]))

    alter table(:ingestion_events) do
      remove(:message)
      remove(:progress)
    end

    alter table(:ingestion_jobs) do
      remove(:last_message)
      remove(:progress)
      remove(:stage)
    end
  end
end
