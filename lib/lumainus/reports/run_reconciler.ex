defmodule Lumainus.Reports.RunReconciler do
  @moduledoc """
  Atomic state reconciliation for report runs.

  Avoids race conditions by using row-level locking and
  always fetching fresh section statuses within transaction.

  Also handles cleanup of context caches when runs complete.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Lumainus.Repo
  alias Lumainus.Reports.{CacheManager, ReportRun, ReportSectionRun}

  require Logger

  @final_statuses ["completed", "error", "timed_out"]

  @doc """
  Atomically check and finalize a report run if all sections are done.

  Uses FOR UPDATE lock to prevent concurrent modifications.
  Idempotent: no-op if already finalized.
  """
  @spec maybe_finalize(Ecto.UUID.t()) :: {:ok, ReportRun} | {:error, term()}
  def maybe_finalize(report_run_id) do
    case Repo.transaction(fn -> finalize_transaction(report_run_id) end) do
      {:ok, {run, finalized?}} ->
        maybe_cleanup_cache(run, finalized?)
        {:ok, run}

      other ->
        other
    end
  end

  @doc """
  Mark a run as timed out, including any running/pending sections.
  """
  @spec mark_timed_out(Ecto.UUID.t()) :: {:ok, ReportRun} | {:error, term()}
  def mark_timed_out(report_run_id) do
    now = DateTime.utc_now(:second)

    case Repo.transaction(fn ->
           run =
             ReportRun
             |> where([r], r.id == ^report_run_id)
             |> lock("FOR UPDATE")
             |> Repo.one!()

           cond do
             run.status in @final_statuses ->
               {run, true}

             run.status in ["running", "pending", "queued"] ->
               ReportSectionRun
               |> where([s], s.report_run_id == ^report_run_id)
               |> where([s], s.status in ["pending", "queued", "running"])
               |> Repo.update_all(set: [status: "timed_out", updated_at: now])

               updated =
                 run
                 |> Changeset.change(%{
                   status: "timed_out",
                   finished_at: now,
                   last_activity_at: now
                 })
                 |> Repo.update!()

               {updated, true}

             true ->
               {run, false}
           end
         end) do
      {:ok, {run, finalized?}} ->
        maybe_cleanup_cache(run, finalized?)
        {:ok, run}

      other ->
        other
    end
  end

  defp fetch_section_statuses(report_run_id) do
    ReportSectionRun
    |> where([s], s.report_run_id == ^report_run_id)
    |> select([s], s.status)
    |> Repo.all()
  end

  defp compute_final_status(statuses) do
    cond do
      # Empty sections is an error state
      statuses == [] ->
        "error"

      # Any section still processing -> not done yet
      Enum.any?(statuses, &(&1 in ["pending", "queued", "running"])) ->
        nil

      # All done, any errors -> error
      Enum.any?(statuses, &(&1 in ["error", "timed_out"])) ->
        "error"

      # All completed successfully
      Enum.all?(statuses, &(&1 == "completed")) ->
        "completed"

      # Unexpected state (unknown status)
      true ->
        "error"
    end
  end

  defp finalize_transaction(report_run_id) do
    run =
      ReportRun
      |> where([r], r.id == ^report_run_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    cond do
      run.status in @final_statuses ->
        {run, true}

      run.status in ["running", "pending", "queued"] ->
        section_statuses = fetch_section_statuses(report_run_id)
        now = DateTime.utc_now(:second)

        case compute_final_status(section_statuses) do
          nil ->
            updated =
              run
              |> Changeset.change(%{last_activity_at: now})
              |> Repo.update!()

            {updated, false}

          final_status ->
            updated =
              run
              |> Changeset.change(%{
                status: final_status,
                finished_at: now,
                last_activity_at: now
              })
              |> Repo.update!()

            {updated, true}
        end

      true ->
        {run, false}
    end
  end

  defp maybe_cleanup_cache(%ReportRun{} = run, true) do
    case CacheManager.delete_cache(run.cached_content_name) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[RunReconciler] Failed to delete cache for run #{run.id}: #{inspect(reason)}"
        )
    end
  end

  defp maybe_cleanup_cache(_run, _finalized?), do: :ok
end
