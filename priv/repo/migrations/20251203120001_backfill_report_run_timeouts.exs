defmodule Medlum.Repo.Migrations.BackfillReportRunTimeouts do
  use Ecto.Migration

  def up do
    # Set timeout_at for existing runs with started_at
    # Uses 30 minute timeout from started_at
    execute("""
      UPDATE report_runs
      SET timeout_at = started_at + interval '30 minutes',
          last_activity_at = COALESCE(finished_at, started_at, inserted_at)
      WHERE started_at IS NOT NULL
        AND timeout_at IS NULL
    """)

    # For runs without started_at, use inserted_at
    execute("""
      UPDATE report_runs
      SET timeout_at = inserted_at + interval '30 minutes',
          last_activity_at = COALESCE(finished_at, inserted_at)
      WHERE started_at IS NULL
        AND timeout_at IS NULL
    """)

    # Fix currently stuck runs (running for 30+ minutes)
    execute("""
      UPDATE report_runs
      SET status = 'timed_out',
          finished_at = NOW()
      WHERE status = 'running'
        AND started_at < NOW() - interval '30 minutes'
    """)

    # Also mark orphan section runs
    execute("""
      UPDATE report_section_runs
      SET status = 'timed_out'
      WHERE status IN ('pending', 'queued', 'running')
        AND report_run_id IN (
          SELECT id FROM report_runs WHERE status = 'timed_out'
        )
    """)
  end

  def down do
    # Revert timed_out to error (close enough)
    execute("""
      UPDATE report_runs SET status = 'error' WHERE status = 'timed_out'
    """)

    execute("""
      UPDATE report_section_runs SET status = 'error' WHERE status = 'timed_out'
    """)
  end
end
