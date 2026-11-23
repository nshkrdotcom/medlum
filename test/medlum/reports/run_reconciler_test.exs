defmodule Medlum.Reports.RunReconcilerTest do
  use Medlum.DataCase

  import Medlum.AccountsFixtures

  alias Medlum.Reports
  alias Medlum.Reports.{ReportRun, ReportSectionRun, RunReconciler}
  alias Medlum.Repo

  setup do
    scope = user_scope_fixture()
    Reports.bootstrap_workspace!(scope)
    workspace = Reports.workspace(scope)

    {:ok, scope: scope, workspace: workspace}
  end

  describe "maybe_finalize/1" do
    test "marks run as completed when all sections completed", %{workspace: workspace} do
      run = create_run(workspace, status: "running")
      create_section_run(run, workspace, status: "completed")
      create_section_run(run, workspace, status: "completed")

      assert {:ok, updated_run} = RunReconciler.maybe_finalize(run.id)

      assert updated_run.status == "completed"
      assert updated_run.finished_at != nil
    end

    test "does NOT finalize run when section has error (Oban may retry)", %{workspace: workspace} do
      run = create_run(workspace, status: "running")
      create_section_run(run, workspace, status: "completed")
      create_section_run(run, workspace, status: "error")

      assert {:ok, updated_run} = RunReconciler.maybe_finalize(run.id)

      # Run stays in "running" because "error" means Oban may still retry
      assert updated_run.status == "running"
      assert updated_run.finished_at == nil
    end

    test "marks run as error when any section has failed (exhausted retries)", %{
      workspace: workspace
    } do
      run = create_run(workspace, status: "running")
      create_section_run(run, workspace, status: "completed")
      create_section_run(run, workspace, status: "failed")

      assert {:ok, updated_run} = RunReconciler.maybe_finalize(run.id)

      assert updated_run.status == "error"
      assert updated_run.finished_at != nil
    end

    test "marks run as error when any section timed_out", %{workspace: workspace} do
      run = create_run(workspace, status: "running")
      create_section_run(run, workspace, status: "completed")
      create_section_run(run, workspace, status: "timed_out")

      assert {:ok, updated_run} = RunReconciler.maybe_finalize(run.id)

      assert updated_run.status == "error"
      assert updated_run.finished_at != nil
    end

    test "bumps last_activity_at when sections still pending", %{workspace: workspace} do
      old_time = DateTime.add(DateTime.utc_now(:second), -60, :second)
      run = create_run(workspace, status: "running", last_activity_at: old_time)
      create_section_run(run, workspace, status: "completed")
      create_section_run(run, workspace, status: "pending")

      assert {:ok, updated_run} = RunReconciler.maybe_finalize(run.id)

      assert updated_run.status == "running"
      assert updated_run.finished_at == nil
      assert DateTime.compare(updated_run.last_activity_at, old_time) == :gt
    end

    test "no-op when run already completed", %{workspace: workspace} do
      finished_at = DateTime.utc_now(:second)
      run = create_run(workspace, status: "completed", finished_at: finished_at)
      create_section_run(run, workspace, status: "completed")

      assert {:ok, unchanged_run} = RunReconciler.maybe_finalize(run.id)

      assert unchanged_run.status == "completed"
      assert unchanged_run.finished_at == finished_at
    end

    test "no-op when run already error", %{workspace: workspace} do
      finished_at = DateTime.utc_now(:second)
      run = create_run(workspace, status: "error", finished_at: finished_at)
      create_section_run(run, workspace, status: "error")

      assert {:ok, unchanged_run} = RunReconciler.maybe_finalize(run.id)

      assert unchanged_run.status == "error"
      assert unchanged_run.finished_at == finished_at
    end

    test "handles concurrent calls safely", %{workspace: workspace} do
      run = create_run(workspace, status: "running")
      create_section_run(run, workspace, status: "completed")
      create_section_run(run, workspace, status: "completed")

      # Spawn multiple processes to call maybe_finalize concurrently
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            RunReconciler.maybe_finalize(run.id)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All calls should succeed
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # Run should be completed exactly once
      final_run = Repo.get!(ReportRun, run.id)
      assert final_run.status == "completed"
      assert final_run.finished_at != nil
    end

    test "marks run as error when no sections exist (unexpected state)", %{workspace: workspace} do
      run = create_run(workspace, status: "running")

      assert {:ok, updated_run} = RunReconciler.maybe_finalize(run.id)

      assert updated_run.status == "error"
    end
  end

  describe "mark_timed_out/1" do
    test "marks running run as timed_out", %{workspace: workspace} do
      run = create_run(workspace, status: "running")
      create_section_run(run, workspace, status: "completed")
      pending_section = create_section_run(run, workspace, status: "pending")

      assert {:ok, updated_run} = RunReconciler.mark_timed_out(run.id)

      assert updated_run.status == "timed_out"
      assert updated_run.finished_at != nil

      # Pending section should also be marked timed_out
      updated_section = Repo.get!(ReportSectionRun, pending_section.id)
      assert updated_section.status == "timed_out"
    end

    test "marks all pending/running sections as timed_out", %{workspace: workspace} do
      run = create_run(workspace, status: "running")
      completed_section = create_section_run(run, workspace, status: "completed")
      pending_section = create_section_run(run, workspace, status: "pending")
      running_section = create_section_run(run, workspace, status: "running")
      queued_section = create_section_run(run, workspace, status: "queued")

      assert {:ok, _} = RunReconciler.mark_timed_out(run.id)

      # Completed stays completed
      assert Repo.get!(ReportSectionRun, completed_section.id).status == "completed"
      # Others become timed_out
      assert Repo.get!(ReportSectionRun, pending_section.id).status == "timed_out"
      assert Repo.get!(ReportSectionRun, running_section.id).status == "timed_out"
      assert Repo.get!(ReportSectionRun, queued_section.id).status == "timed_out"
    end

    test "no-op when run already finalized", %{workspace: workspace} do
      finished_at = DateTime.utc_now(:second)
      run = create_run(workspace, status: "completed", finished_at: finished_at)
      create_section_run(run, workspace, status: "completed")

      assert {:ok, unchanged_run} = RunReconciler.mark_timed_out(run.id)

      assert unchanged_run.status == "completed"
      assert unchanged_run.finished_at == finished_at
    end

    test "marks queued run as timed_out", %{workspace: workspace} do
      run = create_run(workspace, status: "queued")
      create_section_run(run, workspace, status: "queued")

      assert {:ok, updated_run} = RunReconciler.mark_timed_out(run.id)

      assert updated_run.status == "timed_out"
    end
  end

  # Helper functions for creating test data

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
