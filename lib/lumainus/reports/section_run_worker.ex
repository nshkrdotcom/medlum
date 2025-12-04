defmodule Lumainus.Reports.SectionRunWorker do
  @moduledoc """
  Oban worker responsible for executing report section runs asynchronously.
  """

  use Oban.Worker, queue: :reports, max_attempts: 3

  alias Ecto.Changeset
  alias Lumainus.Accounts.Scope
  alias Lumainus.AI.SectionRunner
  alias Lumainus.Reports.{ReportRun, ReportSectionRun, RunReconciler}
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
    documents = Reports.list_documents_with_chunks(scope, report_run.record_set)

    result = SectionRunner.run_section(scope, section_run, patient, documents)

    RunReconciler.maybe_finalize(report_run.id)
    Reports.notify_section_run_update(report_run.record_set_id)

    case result do
      {:ok, _run} -> :ok
      {:error, _run} -> :ok
    end
  end

  defp ensure_run_running(%ReportRun{} = report_run) do
    now = DateTime.utc_now(:second)

    if report_run.status in ["queued", "pending"] do
      Repo.update!(
        Changeset.change(report_run, %{
          status: "running",
          started_at: now,
          last_activity_at: now
        })
      )
    else
      report_run
    end
  end
end
