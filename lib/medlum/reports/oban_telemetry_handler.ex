defmodule Medlum.Reports.ObanTelemetryHandler do
  @moduledoc """
  Handles Oban telemetry events for report section runs.

  Listens for job discard events (max retries exhausted) and marks
  the corresponding section_run as "failed" (terminal) vs "error" (retrying).

  Call `attach/0` during application startup to enable.
  """

  import Ecto.Query

  alias Medlum.Repo
  alias Medlum.Reports.{ReportSectionRun, RunReconciler}

  require Logger

  @doc """
  Attach handlers to Oban telemetry events.
  """
  def attach do
    :telemetry.attach(
      "medlum-oban-section-run-handler",
      [:oban, :job, :exception],
      &handle_event/4,
      nil
    )
  end

  @doc """
  Detach handlers (useful for testing).
  """
  def detach do
    :telemetry.detach("medlum-oban-section-run-handler")
  end

  @doc """
  Handle Oban job exception events.

  When a SectionRunWorker job is discarded (max retries exhausted),
  mark the section_run as "failed" to distinguish from retryable "error".
  """
  def handle_event([:oban, :job, :exception], _measurements, metadata, _config) do
    %{job: job, state: state} = metadata

    # Only handle discarded SectionRunWorker jobs
    if state == :discard and job.worker == "Medlum.Reports.SectionRunWorker" do
      handle_discarded_section_run(job)
    end

    :ok
  end

  defp handle_discarded_section_run(%Oban.Job{args: %{"section_run_id" => section_run_id}} = job) do
    Logger.warning(
      "[ObanTelemetryHandler] SectionRunWorker discarded after #{job.attempt} attempts, " <>
        "section_run_id=#{section_run_id}"
    )

    # Update section_run status to "failed" (terminal)
    ReportSectionRun
    |> where([s], s.id == ^section_run_id)
    |> Repo.update_all(set: [status: "failed", updated_at: DateTime.utc_now()])

    # Notify LiveView of the change
    section_run = Repo.get(ReportSectionRun, section_run_id)

    if section_run do
      report_run =
        Medlum.Reports.ReportRun
        |> Repo.get(section_run.report_run_id)

      if report_run do
        Medlum.Reports.notify_section_run_update(report_run.record_set_id)
        RunReconciler.maybe_finalize(report_run.id)
      end
    end
  end

  defp handle_discarded_section_run(_job), do: :ok
end
