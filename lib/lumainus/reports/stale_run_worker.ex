defmodule Lumainus.Reports.StaleRunWorker do
  @moduledoc """
  Oban cron worker that detects and fixes stale report runs.

  Runs every 5 minutes to:
  1. Find runs past timeout_at -> mark as timed_out
  2. Find runs where all sections done but run still "running" -> finalize
  3. Find runs inactive for 10+ minutes -> investigate/timeout
  4. Find section_runs stuck "running" with no active Oban job -> mark as error
  5. Find LLM invocations stuck "pending" for 10+ minutes -> mark as error
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Ecto.Changeset
  alias Lumainus.Repo
  alias Lumainus.AI.{LlmInvocation, Telemetry}
  alias Lumainus.Reports.{ReportRun, ReportSectionRun, RunReconciler}

  require Logger

  @stale_activity_minutes 10
  # Pending invocations should transition to running quickly (30 seconds)
  # If still pending after this, the process crashed before LLM call started
  @stale_pending_seconds 30
  # Running invocations can take a long time for large documents
  # 20 minutes allows for slow LLM responses
  @stale_running_minutes 20

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    timed_out_count = process_past_timeout(now)
    orphaned_count = process_orphaned_running()
    stale_count = process_stale_activity(now)
    orphaned_sections_count = process_orphaned_section_runs()
    {stale_pending, stale_running} = process_stale_llm_invocations(now)

    if timed_out_count > 0 or orphaned_count > 0 or stale_count > 0 or
         orphaned_sections_count > 0 or stale_pending > 0 or stale_running > 0 do
      Logger.info(
        "StaleRunWorker: #{timed_out_count} timed out, " <>
          "#{orphaned_count} orphaned finalized, #{stale_count} stale marked, " <>
          "#{orphaned_sections_count} orphaned sections, " <>
          "#{stale_pending} stale pending LLM, #{stale_running} stale running LLM"
      )
    end

    :ok
  end

  defp process_past_timeout(now) do
    runs = find_past_timeout(now)
    Enum.each(runs, &RunReconciler.mark_timed_out(&1.id))
    length(runs)
  end

  defp process_orphaned_running do
    runs = find_orphaned_running()
    Enum.each(runs, &RunReconciler.maybe_finalize(&1.id))
    length(runs)
  end

  defp process_stale_activity(now) do
    runs = find_stale_activity(now)
    Enum.each(runs, &RunReconciler.mark_timed_out(&1.id))
    length(runs)
  end

  defp find_past_timeout(now) do
    ReportRun
    |> where([r], r.status in ["running", "pending", "queued"])
    |> where([r], not is_nil(r.timeout_at) and r.timeout_at < ^now)
    |> Repo.all()
  end

  defp find_orphaned_running do
    running_run_ids =
      ReportRun
      |> where([r], r.status == "running")
      |> select([r], r.id)
      |> Repo.all()

    Enum.filter(running_run_ids, fn run_id ->
      active_count =
        ReportSectionRun
        |> where([s], s.report_run_id == ^run_id)
        |> where([s], s.status in ["pending", "queued", "running"])
        |> Repo.aggregate(:count)

      active_count == 0
    end)
    |> Enum.map(&%{id: &1})
  end

  defp find_stale_activity(now) do
    stale_threshold = DateTime.add(now, -@stale_activity_minutes, :minute)

    ReportRun
    |> where([r], r.status == "running")
    |> where([r], not is_nil(r.last_activity_at) and r.last_activity_at < ^stale_threshold)
    |> Repo.all()
  end

  # Find section_runs stuck in "running" state but their Oban job is no longer executing
  defp process_orphaned_section_runs do
    # Get all section_runs in "running" status
    running_sections =
      ReportSectionRun
      |> where([s], s.status == "running")
      |> Repo.all()

    # For each, check if there's an active Oban job
    orphaned =
      Enum.filter(running_sections, fn section ->
        job =
          Oban.Job
          |> where([j], fragment("?->>'section_run_id' = ?", j.args, ^section.id))
          |> where([j], j.state in ["available", "executing", "scheduled", "retryable"])
          |> Repo.one()

        is_nil(job)
      end)

    # Mark orphaned sections as error
    Enum.each(orphaned, fn section ->
      Repo.update!(
        Changeset.change(section, %{
          status: "error",
          error: %{
            "type" => "orphaned",
            "message" => "Section run was orphaned - no active Oban job found"
          }
        })
      )

      Logger.warning("[StaleRunWorker] Marked orphaned section_run #{section.id} as error")
    end)

    length(orphaned)
  end

  # Find LLM invocations stuck in "pending" or "running" for too long
  defp process_stale_llm_invocations(now) do
    pending_count = process_stale_pending_invocations(now)
    running_count = process_stale_running_invocations(now)
    {pending_count, running_count}
  end

  # Pending > 30s means process crashed before LLM call started
  defp process_stale_pending_invocations(now) do
    stale_threshold = DateTime.add(now, -@stale_pending_seconds, :second)

    stale_invocations =
      LlmInvocation
      |> where([i], i.status == "pending")
      |> where([i], i.inserted_at < ^stale_threshold)
      |> Repo.all()

    Enum.each(stale_invocations, fn invocation ->
      age_seconds = DateTime.diff(now, invocation.inserted_at, :second)
      model = "#{invocation.provider}:#{invocation.model}"

      Telemetry.emit_invocation_orphaned(
        invocation.id,
        model,
        div(age_seconds, 60),
        :stale_pending
      )

      Repo.update!(
        Changeset.change(invocation, %{
          status: "error",
          error: %{
            "type" => "never_started",
            "message" => "LLM invocation never started - stuck pending for #{age_seconds}s"
          }
        })
      )

      Logger.warning(
        "[StaleRunWorker] Invocation #{invocation.id} never started (pending #{age_seconds}s)"
      )
    end)

    length(stale_invocations)
  end

  # Running > 20min means LLM call hung or process crashed during call
  defp process_stale_running_invocations(now) do
    stale_threshold = DateTime.add(now, -@stale_running_minutes, :minute)

    stale_invocations =
      LlmInvocation
      |> where([i], i.status == "running")
      |> where([i], i.updated_at < ^stale_threshold)
      |> Repo.all()

    Enum.each(stale_invocations, fn invocation ->
      age_minutes = DateTime.diff(now, invocation.updated_at, :minute)
      model = "#{invocation.provider}:#{invocation.model}"

      Telemetry.emit_invocation_orphaned(invocation.id, model, age_minutes, :stale_running)

      Repo.update!(
        Changeset.change(invocation, %{
          status: "error",
          error: %{
            "type" => "llm_timeout",
            "message" => "LLM call timed out - running for over #{age_minutes} minutes"
          }
        })
      )

      Logger.warning(
        "[StaleRunWorker] Invocation #{invocation.id} timed out (running #{age_minutes}min)"
      )
    end)

    length(stale_invocations)
  end
end
