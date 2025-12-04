defmodule Lumainus.Reports.StaleRunWorker do
  @moduledoc """
  Oban cron worker that detects and fixes stale report runs.

  Runs every 5 minutes to:
  1. Find runs past timeout_at -> mark as timed_out
  2. Find runs where all sections done but run still "running" -> finalize
  3. Find runs inactive for 10+ minutes -> investigate/timeout
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Lumainus.Repo
  alias Lumainus.Reports.{ReportRun, ReportSectionRun, RunReconciler}

  require Logger

  @stale_activity_minutes 10

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    timed_out_count = process_past_timeout(now)
    orphaned_count = process_orphaned_running()
    stale_count = process_stale_activity(now)

    if timed_out_count > 0 or orphaned_count > 0 or stale_count > 0 do
      Logger.info(
        "StaleRunWorker: #{timed_out_count} timed out, " <>
          "#{orphaned_count} orphaned finalized, #{stale_count} stale marked"
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
end
