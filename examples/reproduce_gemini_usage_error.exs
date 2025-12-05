Mix.Task.run("app.start")

alias Lumainus.Accounts.{Scope, User}
alias Lumainus.AI.SectionRunner
alias Lumainus.Documents
alias Lumainus.Repo
alias Lumainus.Reports
alias Lumainus.Reports.{ReportRun, ReportSectionRun}

defmodule Examples.GeminiUsageError do
  @moduledoc false

  def run do
    header()

    scope = scope!()
    Reports.bootstrap_workspace!(scope)

    workspace = prepare_workspace(scope)
    section_template = pick_section_template(workspace)

    patient = Repo.preload(workspace.patient, :current_profile)
    documents = Reports.list_documents(scope, workspace.record_set)
    section_run = create_section_run(scope, workspace, section_template)

    IO.puts(
      "\n==> Running SectionRunner for #{section_template.title} (#{section_template.identifier})"
    )

    try do
      case SectionRunner.run_section(scope, section_run, patient, documents) do
        {:ok, run} ->
          IO.puts("✓ SectionRunner completed.")
          dump_run(run)

        {:error, run} ->
          IO.puts("✗ SectionRunner returned error.")
          dump_run(run)
      end
    rescue
      error ->
        IO.puts("🔥 Unhandled exception thrown during generation:")
        IO.puts(Exception.format(:error, error, __STACKTRACE__))
    end
  end

  defp header do
    IO.puts("\n=== GeminiEx Structured Output Reproduction ===\n")

    IO.puts("""
    This script creates a new report-section run and invokes Lumainus.AI.SectionRunner
    exactly like the /reports UI. Use it to reproduce structured-output errors such as
    missing usage metadata fields from the live GeminiEx client.
    """)
  end

  defp scope! do
    email = System.get_env("MEDLUMAI_SAMPLE_USER") || "admin@medlumai.local"

    user =
      Repo.get_by(User, email: email) ||
        raise """
        Could not find user #{email}.
        Run `mix run priv/repo/seeds.exs` or set MEDLUMAI_SAMPLE_USER.
        """

    IO.puts("Running as #{email}")
    Scope.for_user(user)
  end

  defp prepare_workspace(scope) do
    workspace = Reports.workspace(scope)
    Documents.seed_sample_documents(scope, workspace.patient, workspace.record_set)
    Reports.workspace(scope)
  end

  defp pick_section_template(workspace) do
    identifier =
      System.get_env("MEDLUMAI_SECTION_IDENTIFIER") ||
        "diagnostics-overview"

    title =
      System.get_env("MEDLUMAI_SECTION_TITLE") ||
        "Diagnostics Overview"

    sections =
      workspace.template.sections
      |> Enum.sort_by(& &1.position, :asc)

    section_by_identifier =
      Enum.find(
        sections,
        &(String.downcase(&1.identifier) == String.downcase(identifier))
      )

    section_by_title =
      Enum.find(
        sections,
        &(String.downcase(&1.title) == String.downcase(title))
      )

    cond do
      section_by_identifier ->
        section_by_identifier

      section_by_title ->
        section_by_title

      true ->
        IO.puts(
          "No section hint provided. Defaulting to first section (set MEDLUMAI_SECTION_IDENTIFIER or MEDLUMAI_SECTION_TITLE to override)."
        )

        List.first(sections) || raise("No sections found on template #{workspace.template.id}")
    end
  end

  defp create_section_run(scope, workspace, section_template) do
    tenant_id = scope.tenant_id || (scope.tenant && scope.tenant.id) || scope.user.tenant_id

    run =
      %ReportRun{}
      |> ReportRun.changeset(%{
        tenant_id: tenant_id,
        patient_id: workspace.patient.id,
        record_set_id: workspace.record_set.id,
        template_id: workspace.template.id,
        run_type: "section",
        status: "queued",
        triggered_by_user_id: scope.user.id
      })
      |> Repo.insert!()

    %ReportSectionRun{}
    |> ReportSectionRun.changeset(%{
      report_run_id: run.id,
      section_template_id: section_template.id,
      status: "queued"
    })
    |> Repo.insert!()
  end

  defp dump_run(run) do
    IO.puts("\nStatus: #{run.status}")

    if run.error do
      IO.puts("\nError payload:")
      IO.inspect(run.error, pretty: true, limit: :infinity)
    end

    IO.puts("\nOutput markdown sample:")
    IO.puts((run.output_markdown || "") |> String.slice(0, 500))

    IO.puts("\nStructured object:")
    IO.inspect(run.output_object || %{}, pretty: true, limit: :infinity)
  end
end

Examples.GeminiUsageError.run()
