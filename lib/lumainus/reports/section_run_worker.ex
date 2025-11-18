defmodule Lumainus.Reports.SectionRunWorker do
  @moduledoc """
  Oban worker responsible for executing report section runs asynchronously.
  """

  use Oban.Worker, queue: :reports, max_attempts: 3

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Lumainus.Accounts.Scope
  alias Lumainus.AI.SectionRunner
  alias Lumainus.Reports.{ReportRun, ReportSectionRun}
  alias Lumainus.{Repo, Reports}

  @impl true
  def perform(%Oban.Job{args: %{"section_run_id" => section_run_id}}) do
    section_run =
      ReportSectionRun
      |> Repo.get!(section_run_id)
      |> Repo.preload([
        :section_template,
        report_run: [:template, :patient, :record_set]
      ])

    report_run = ensure_run_running(section_run.report_run)
    patient = Repo.preload(report_run.patient, :current_profile)
    scope = %Scope{tenant_id: report_run.tenant_id}
    documents = Reports.list_documents(scope, report_run.record_set)

    result = SectionRunner.run_section(scope, section_run, patient, documents)

    finalize_run_state(report_run, result)
    Reports.notify_section_run_update(report_run.record_set_id)

    result
    |> case do
      {:ok, _run} -> :ok
      {:error, _run} -> :ok
    end
  end

  defp ensure_run_running(%ReportRun{} = report_run) do
    if report_run.status in ["queued", "pending"] do
      Repo.update!(
        Changeset.change(report_run, %{
          status: "running",
          started_at: DateTime.utc_now(:second)
        })
      )
    else
      report_run
    end
  end

  defp finalize_run_state(report_run, {:error, _section_run}) do
    Repo.update!(
      Changeset.change(report_run, %{
        status: "error",
        finished_at: DateTime.utc_now(:second)
      })
    )
  end

  defp finalize_run_state(report_run, {:ok, _section_run}) do
    statuses =
      ReportSectionRun
      |> where([sr], sr.report_run_id == ^report_run.id)
      |> select([sr], sr.status)
      |> Repo.all()

    cond do
      Enum.any?(statuses, &(&1 == "error")) ->
        Repo.update!(
          Changeset.change(report_run, %{
            status: "error",
            finished_at: DateTime.utc_now(:second)
          })
        )

      Enum.all?(statuses, &(&1 == "completed")) ->
        Repo.update!(
          Changeset.change(report_run, %{
            status: "completed",
            finished_at: DateTime.utc_now(:second)
          })
        )

      true ->
        :ok
    end
  end
end
