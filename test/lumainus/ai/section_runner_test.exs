defmodule Lumainus.AI.SectionRunnerTest do
  use Lumainus.DataCase

  import Lumainus.AccountsFixtures

  alias Ecto.Changeset
  alias Lumainus.Accounts.Scope
  alias Lumainus.AI.SectionRunner
  alias Lumainus.Documents
  alias Lumainus.Reports
  alias Lumainus.Reports.{ReportRun, ReportSectionRun}
  alias Lumainus.Repo

  setup do
    user = user_fixture()
    {:ok, user} = Repo.update(Changeset.change(user, role: "doctor"))
    scope = Scope.for_user(user)

    Reports.bootstrap_workspace!(scope)
    workspace = Reports.workspace(scope)

    Documents.seed_sample_documents(scope, workspace.patient, workspace.record_set)

    fresh_workspace = Reports.workspace(scope)
    documents = Reports.list_documents(scope, fresh_workspace.record_set)
    patient = Repo.preload(fresh_workspace.patient, :current_profile)
    section_template = hd(fresh_workspace.template.sections)

    run =
      %ReportRun{}
      |> ReportRun.changeset(%{
        tenant_id: scope.tenant_id,
        patient_id: patient.id,
        record_set_id: fresh_workspace.record_set.id,
        template_id: fresh_workspace.template.id,
        run_type: "section",
        status: "queued"
      })
      |> Repo.insert!()

    section_run =
      %ReportSectionRun{}
      |> ReportSectionRun.changeset(%{
        report_run_id: run.id,
        section_template_id: section_template.id,
        status: "queued"
      })
      |> Repo.insert!()

    {:ok, scope: scope, patient: patient, documents: documents, section_run: section_run}
  end

  test "persists markdown output and citations", %{
    scope: scope,
    patient: patient,
    documents: documents,
    section_run: section_run
  } do
    {:ok, _run} = SectionRunner.run_section(scope, section_run, patient, documents)

    reloaded =
      ReportSectionRun
      |> Repo.get!(section_run.id)
      |> Repo.preload(:citations)

    assert reloaded.status == "completed"
    assert reloaded.output_markdown =~ "Mock Section Output"
    assert length(reloaded.citations) == 1
    assert hd(reloaded.citations).document_id
  end

  test "marks section as error when client fails", %{
    scope: scope,
    patient: patient,
    documents: documents,
    section_run: section_run
  } do
    with_llm_client(Lumainus.AI.SectionRunnerTest.FailingClient, fn ->
      {:error, _run} = SectionRunner.run_section(scope, section_run, patient, documents)

      reloaded = Repo.get!(ReportSectionRun, section_run.id)
      assert reloaded.status == "error"
      assert reloaded.error["message"] =~ "failing"
    end)
  end

  defmodule FailingClient do
    @behaviour Lumainus.LLM.Client

    @impl true
    def generate_object(_model_spec, _messages, _schema, _opts \\ []) do
      {:error, %RuntimeError{message: "failing client"}}
    end
  end

  defp with_llm_client(client, fun) do
    original = Application.get_env(:lumainus, :llm, [])
    updated = Keyword.put(original, :client, client)

    try do
      Application.put_env(:lumainus, :llm, updated)
      fun.()
    after
      Application.put_env(:lumainus, :llm, original)
    end
  end
end
