defmodule Medlum.Repo.Migrations.AddIngestionJobRobustQueueFields do
  use Ecto.Migration

  def up do
    alter table(:ingestion_jobs) do
      # Retry tracking
      add(:attempt_number, :integer, null: false, default: 1)
      add(:max_attempts, :integer, null: false, default: 3)
      add(:next_retry_at, :utc_datetime)

      # Hard deadline across all retries
      add(:deadline_at, :utc_datetime)

      # Lifecycle tracking
      add(:cancelled_at, :utc_datetime)
      add(:archived_at, :utc_datetime)

      # Error history for debugging
      add(:error_history, {:array, :map}, null: false, default: [])

      # Link to Oban job for cancellation
      add(:oban_job_id, :bigint)

      # Docling job ID for tracking
      add(:docling_job_id, :string)
    end

    create(index(:ingestion_jobs, [:deadline_at]))
    create(index(:ingestion_jobs, [:archived_at]))
    create(index(:ingestion_jobs, [:oban_job_id]))

    # Set deadline_at for existing jobs to timeout_at
    execute("""
    UPDATE ingestion_jobs
    SET deadline_at = timeout_at
    WHERE timeout_at IS NOT NULL
    """)

    # Set max_attempts for existing jobs based on current attempts
    execute("""
    UPDATE ingestion_jobs
    SET max_attempts = GREATEST(3, COALESCE(attempts, 1))
    """)
  end

  def down do
    drop_if_exists(index(:ingestion_jobs, [:deadline_at]))
    drop_if_exists(index(:ingestion_jobs, [:archived_at]))
    drop_if_exists(index(:ingestion_jobs, [:oban_job_id]))

    alter table(:ingestion_jobs) do
      remove(:attempt_number)
      remove(:max_attempts)
      remove(:next_retry_at)
      remove(:deadline_at)
      remove(:cancelled_at)
      remove(:archived_at)
      remove(:error_history)
      remove(:oban_job_id)
      remove(:docling_job_id)
    end
  end
end
