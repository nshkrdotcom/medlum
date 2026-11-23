Mix.Task.run("app.start")

alias Medlum.Accounts.{Scope, User}
alias Medlum.Documents
alias Medlum.Repo
alias Medlum.Reports
alias Medlum.Reports.{ReportRun, ReportSectionRun}
alias Medlum.AI.SectionRunner

defmodule Samples.RunSection do
  @moduledoc false

  def go do
    email = System.get_env("MEDLUMAI_SAMPLE_USER") || "admin@medlumai.local"
    IO.puts("\n== Running sample section as #{email}\n")

    user =
      Repo.get_by(User, email: email) ||
        raise """
        Could not find user with email #{email}.
        Make sure you've run `mix run priv/repo/seeds.exs` or set MEDLUMAI_SAMPLE_USER.
        """

    scope = Scope.for_user(user)
    Reports.bootstrap_workspace!(scope)

    workspace = Reports.workspace(scope)
    Documents.seed_sample_documents(scope, workspace.patient, workspace.record_set)
    workspace = Reports.workspace(scope)

    documents = Reports.list_documents(scope, workspace.record_set)
    patient = Repo.preload(workspace.patient, :current_profile)
    section_template = hd(workspace.template.sections)

    tenant_id = scope.tenant_id || (scope.tenant && scope.tenant.id) || user.tenant_id

    run =
      %ReportRun{}
      |> ReportRun.changeset(%{
        tenant_id: tenant_id,
        patient_id: patient.id,
        record_set_id: workspace.record_set.id,
        template_id: workspace.template.id,
        run_type: "section",
        status: "queued",
        triggered_by_user_id: user.id
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

    IO.puts("Running section #{section_template.title}…\n")

    case SectionRunner.run_section(scope, section_run, patient, documents) do
      {:ok, run} ->
        IO.puts("✅ Success!")
        IO.puts("\nMarkdown output:\n")
        IO.puts(run.output_markdown || "[no markdown returned]")
        IO.puts("\nStructured object:\n")
        IO.inspect(run.output_object, pretty: true, limit: :infinity)

      {:error, run} ->
        IO.puts("❌ Failed. Error payload:\n")
        IO.inspect(run.error, pretty: true)
    end
  end
end

Samples.RunSection.go()
