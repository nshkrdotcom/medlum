defmodule Lumainus.Reports.StaleRunWorkerTest do
  use Lumainus.DataCase

  import Lumainus.AccountsFixtures

  alias Lumainus.Reports
  alias Lumainus.Reports.{ReportRun, ReportSectionRun, StaleRunWorker}
  alias Lumainus.Repo

  setup do
    scope = user_scope_fixture()
    Reports.bootstrap_workspace!(scope)
    workspace = Reports.workspace(scope)

    {:ok, scope: scope, workspace: workspace}
  end

  describe "perform/1" do
    test "marks runs past timeout_at as timed_out", %{workspace: workspace} do
      past_timeout = DateTime.add(DateTime.utc_now(:second), -5, :minute)

      run =
        create_run(workspace,
          status: "running",
          timeout_at: past_timeout
        )

      section = create_section_run(run, workspace, status: "running")

      assert :ok = StaleRunWorker.perform(%Oban.Job{})

      updated_run = Repo.get!(ReportRun, run.id)
      assert updated_run.status == "timed_out"
      assert updated_run.finished_at != nil

      updated_section = Repo.get!(ReportSectionRun, section.id)
      assert updated_section.status == "timed_out"
    end

    test "finalizes orphaned running runs (all sections done)", %{workspace: workspace} do
      future_timeout = DateTime.add(DateTime.utc_now(:second), 30, :minute)
      recent_activity = DateTime.utc_now(:second)

      run =
        create_run(workspace,
          status: "running",
          timeout_at: future_timeout,
          last_activity_at: recent_activity
        )

      create_section_run(run, workspace, status: "completed")
      create_section_run(run, workspace, status: "completed")

      assert :ok = StaleRunWorker.perform(%Oban.Job{})

      updated_run = Repo.get!(ReportRun, run.id)
      assert updated_run.status == "completed"
      assert updated_run.finished_at != nil
    end

    test "marks runs with stale activity as timed_out", %{workspace: workspace} do
      future_timeout = DateTime.add(DateTime.utc_now(:second), 30, :minute)
      stale_activity = DateTime.add(DateTime.utc_now(:second), -15, :minute)

      run =
        create_run(workspace,
          status: "running",
          timeout_at: future_timeout,
          last_activity_at: stale_activity
        )

      section = create_section_run(run, workspace, status: "running")

      assert :ok = StaleRunWorker.perform(%Oban.Job{})

      updated_run = Repo.get!(ReportRun, run.id)
      assert updated_run.status == "timed_out"

      updated_section = Repo.get!(ReportSectionRun, section.id)
      assert updated_section.status == "timed_out"
    end

    test "ignores already finalized runs", %{workspace: workspace} do
      past_timeout = DateTime.add(DateTime.utc_now(:second), -5, :minute)
      finished_at = DateTime.utc_now(:second)

      run =
        create_run(workspace,
          status: "completed",
          timeout_at: past_timeout,
          finished_at: finished_at
        )

      create_section_run(run, workspace, status: "completed")

      assert :ok = StaleRunWorker.perform(%Oban.Job{})

      updated_run = Repo.get!(ReportRun, run.id)
      assert updated_run.status == "completed"
      assert updated_run.finished_at == finished_at
    end

    test "ignores runs with recent activity and pending sections", %{workspace: workspace} do
      future_timeout = DateTime.add(DateTime.utc_now(:second), 30, :minute)
      recent_activity = DateTime.utc_now(:second)

      run =
        create_run(workspace,
          status: "running",
          timeout_at: future_timeout,
          last_activity_at: recent_activity
        )

      create_section_run(run, workspace, status: "completed")
      create_section_run(run, workspace, status: "pending")

      assert :ok = StaleRunWorker.perform(%Oban.Job{})

      updated_run = Repo.get!(ReportRun, run.id)
      assert updated_run.status == "running"
    end
  end

  defp create_run(workspace, opts) do
    now = DateTime.utc_now(:second)
    status = Keyword.get(opts, :status, "pending")
    finished_at = Keyword.get(opts, :finished_at)
    last_activity_at = Keyword.get(opts, :last_activity_at, now)
    timeout_at = Keyword.get(opts, :timeout_at, DateTime.add(now, 30, :minute))

    %ReportRun{}
    |> ReportRun.changeset(%{
      tenant_id: workspace.patient.tenant_id,
      patient_id: workspace.patient.id,
      record_set_id: workspace.record_set.id,
      template_id: workspace.template.id,
      run_type: "full",
      status: status,
      started_at: if(status in ["running", "completed", "error"], do: now, else: nil),
      finished_at: finished_at,
      timeout_at: timeout_at,
      last_activity_at: last_activity_at
    })
    |> Repo.insert!()
  end

  defp create_section_run(run, workspace, opts) do
    status = Keyword.get(opts, :status, "pending")
    [section | _] = workspace.template.sections

    %ReportSectionRun{}
    |> ReportSectionRun.changeset(%{
      report_run_id: run.id,
      section_template_id: section.id,
      status: status
    })
    |> Repo.insert!()
  end
end
