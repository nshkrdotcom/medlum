defmodule Medlum.Documents.IngestionCleanupWorker do
  @moduledoc """
  Oban worker for cleaning up stale ingestion jobs and archiving old ones.

  Scheduled via Oban Cron to run periodically. Performs:
  - Marks stale jobs (stuck in processing) as failed
  - Archives old completed/failed jobs
  - Cleans up orphaned uploads
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  alias Ecto.Changeset
  alias Medlum.Documents
  alias Medlum.Documents.{DocumentUpload, IngestionConfig}
  alias Medlum.Repo

  import Ecto.Query

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    Logger.info("Starting ingestion cleanup worker")

    stale_count = cleanup_stale_jobs()
    archived_count = archive_old_jobs()
    orphan_count = cleanup_orphaned_uploads()

    Logger.info(
      "Cleanup complete: #{stale_count} stale jobs marked failed, " <>
        "#{archived_count} jobs archived, #{orphan_count} orphaned uploads cleaned"
    )

    :ok
  end

  @doc """
  Marks jobs stuck in processing state as failed.
  """
  def cleanup_stale_jobs do
    stale_jobs = Documents.find_stale_jobs()

    Enum.each(stale_jobs, fn job ->
      Logger.warning("Marking stale job #{job.id} as failed (last updated: #{job.updated_at})")

      job
      |> Changeset.change(%{
        state: "failed",
        status: "failed",
        last_error:
          "Marked stale by cleanup worker - no progress for #{IngestionConfig.stale_job_threshold_minutes()} minutes",
        finished_at: DateTime.utc_now(:second)
      })
      |> Repo.update!()

      # Notify UI of the failure
      job_with_upload = Repo.preload(job, :upload)
      Documents.notify_job_progress(job_with_upload)
    end)

    length(stale_jobs)
  end

  @doc """
  Archives old completed/failed jobs.
  """
  def archive_old_jobs do
    jobs_to_archive = Documents.find_jobs_for_archival()

    Enum.each(jobs_to_archive, fn job ->
      {:ok, _} = Documents.archive_job(job)
    end)

    length(jobs_to_archive)
  end

  @doc """
  Cleans up uploads that were never processed.
  """
  def cleanup_orphaned_uploads do
    # Find uploads in pending status older than 1 hour with no ingestion jobs
    cutoff = DateTime.add(DateTime.utc_now(), -1, :hour)

    orphaned =
      DocumentUpload
      |> where([u], u.status == "pending")
      |> where([u], u.inserted_at < ^cutoff)
      |> where(
        [u],
        fragment("NOT EXISTS (SELECT 1 FROM ingestion_jobs WHERE upload_id = ?)", u.id)
      )
      |> Repo.all()

    Enum.each(orphaned, fn upload ->
      Logger.warning("Marking orphaned upload #{upload.id} as failed")

      upload
      |> Changeset.change(%{
        status: "failed",
        metadata:
          Map.merge(upload.metadata || %{}, %{
            "error" => "Orphaned upload - no ingestion job created",
            "orphaned_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })
      })
      |> Repo.update!()

      Documents.notify_documents_changed(upload.record_set_id)
    end)

    length(orphaned)
  end
end
