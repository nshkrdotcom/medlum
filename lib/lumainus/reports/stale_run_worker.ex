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
  alias Lumainus.AI.LlmInvocation
  alias Lumainus.Reports.{ReportRun, ReportSectionRun, RunReconciler}

  require Logger

  @stale_activity_minutes 10
  @stale_llm_minutes 10

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    timed_out_count = process_past_timeout(now)
    orphaned_count = process_orphaned_running()
    stale_count = process_stale_activity(now)
    orphaned_sections_count = process_orphaned_section_runs()
    stale_llm_count = process_stale_llm_invocations(now)

    if timed_out_count > 0 or orphaned_count > 0 or stale_count > 0 or
         orphaned_sections_count > 0 or stale_llm_count > 0 do
      Logger.info(
        "StaleRunWorker: #{timed_out_count} timed out, " <>
          "#{orphaned_count} orphaned finalized, #{stale_count} stale marked, " <>
          "#{orphaned_sections_count} orphaned sections, #{stale_llm_count} stale LLM invocations"
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

  # Find LLM invocations stuck in "pending" for too long
  defp process_stale_llm_invocations(now) do
    stale_threshold = DateTime.add(now, -@stale_llm_minutes, :minute)

    stale_invocations =
      LlmInvocation
      |> where([i], i.status == "pending")
      |> where([i], i.inserted_at < ^stale_threshold)
      |> Repo.all()

    Enum.each(stale_invocations, fn invocation ->
      Repo.update!(
        Changeset.change(invocation, %{
          status: "error",
          error: %{
            "type" => "timeout",
            "message" =>
              "LLM invocation timed out - stuck pending for over #{@stale_llm_minutes} minutes"
          }
        })
      )

      Logger.warning("[StaleRunWorker] Marked stale LLM invocation #{invocation.id} as error")
    end)

    length(stale_invocations)
  end
end
