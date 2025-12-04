defmodule Lumainus.Reports.RunReconciler do
  @moduledoc """
  Atomic state reconciliation for report runs.

  Avoids race conditions by using row-level locking and
  always fetching fresh section statuses within transaction.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Lumainus.Repo
  alias Lumainus.Reports.{ReportRun, ReportSectionRun}

  @doc """
  Atomically check and finalize a report run if all sections are done.

  Uses FOR UPDATE lock to prevent concurrent modifications.
  Idempotent: no-op if already finalized.
  """
  @spec maybe_finalize(Ecto.UUID.t()) :: {:ok, ReportRun} | {:error, term()}
  def maybe_finalize(report_run_id) do
    Repo.transaction(fn ->
      run =
        ReportRun
        |> where([r], r.id == ^report_run_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if run.status in ["running", "pending", "queued"] do
        section_statuses = fetch_section_statuses(report_run_id)
        now = DateTime.utc_now(:second)

        case compute_final_status(section_statuses) do
          nil ->
            run
            |> Changeset.change(%{last_activity_at: now})
            |> Repo.update!()

          final_status ->
            run
            |> Changeset.change(%{
              status: final_status,
              finished_at: now,
              last_activity_at: now
            })
            |> Repo.update!()
        end
      else
        run
      end
    end)
  end

  @doc """
  Mark a run as timed out, including any running/pending sections.
  """
  @spec mark_timed_out(Ecto.UUID.t()) :: {:ok, ReportRun} | {:error, term()}
  def mark_timed_out(report_run_id) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      run =
        ReportRun
        |> where([r], r.id == ^report_run_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if run.status in ["running", "pending", "queued"] do
        ReportSectionRun
        |> where([s], s.report_run_id == ^report_run_id)
        |> where([s], s.status in ["pending", "queued", "running"])
        |> Repo.update_all(set: [status: "timed_out", updated_at: now])

        run
        |> Changeset.change(%{
          status: "timed_out",
          finished_at: now,
          last_activity_at: now
        })
        |> Repo.update!()
      else
        run
      end
    end)
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
end
