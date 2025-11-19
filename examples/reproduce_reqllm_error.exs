Mix.Task.run("app.start")

alias Lumainus.Accounts.{Scope, User}
alias Lumainus.AI.SectionRunner
alias Lumainus.Documents
alias Lumainus.Repo
alias Lumainus.Reports
alias Lumainus.Reports.{ReportRun, ReportSectionRun, ReportSectionTemplate}

defmodule Examples.ReqLLMErrorRepro do
  @moduledoc false

  def run do
    header()

    scope = scope!()
    Reports.bootstrap_workspace!(scope)

    workspace = prepare_workspace(scope)
    section_template = pick_section_template(workspace)
    original_schema = section_template.output_schema || %{}

    print_module_status()
    print_schema("Current schema (from DB)", SectionRunner.schema_to_json(original_schema))

    run_once("CURRENT schema", scope, workspace, section_template)

    run_with_legacy_schema(scope, section_template.id, original_schema)

    IO.puts("\n=== Done ===\n")
  end

  defp prepare_workspace(scope) do
    workspace = Reports.workspace(scope)
    Documents.seed_sample_documents(scope, workspace.patient, workspace.record_set)
    Reports.workspace(scope)
  end

  defp run_once(label, scope, workspace, section_template) do
    IO.puts("\n-- Running SectionRunner with #{label} --")

    patient = Repo.preload(workspace.patient, :current_profile)
    documents = Reports.list_documents(scope, workspace.record_set)
    section_run = create_section_run(scope, workspace, section_template)

    case SectionRunner.run_section(scope, section_run, patient, documents) do
      {:ok, run} ->
        IO.puts("✓ Completed SectionRunner invocation.")
        IO.puts("Markdown preview:\n")
        IO.puts((run.output_markdown || "") |> String.slice(0, 400))
        IO.puts("\nStructured object:\n")
        IO.inspect(run.output_object, limit: :infinity, pretty: true)

      {:error, run} ->
        IO.puts("✗ SectionRunner returned error for #{label}")
        IO.puts("Error payload:")
        IO.inspect(run.error, pretty: true)
    end
  end

  defp run_with_legacy_schema(scope, template_id, original_schema) do
    legacy = legacy_schema(original_schema)
    print_schema("Legacy schema (with items)", SectionRunner.schema_to_json(legacy))

    IO.puts("\nTemporarily persisting legacy schema to reproduce the ReqLLM validation error…")

    template = Repo.get!(ReportSectionTemplate, template_id)
    updated = save_schema(template, legacy)

    try do
      workspace = Reports.workspace(scope)
      section_template = pick_section_template(workspace)
      run_once("LEGACY schema (expected to fail)", scope, workspace, section_template)
    after
      IO.puts("\nRestoring current schema on section template #{template_id}")
      save_schema(updated, original_schema)
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

  defp pick_section_template(workspace) do
    workspace.template.sections
    |> Enum.sort_by(& &1.position, :asc)
    |> List.first()
    |> case do
      nil ->
        raise "No section templates found for workspace template #{workspace.template.id}"

      section ->
        IO.puts("Using section #{section.title} (#{section.identifier})")
        section
    end
  end

  defp legacy_schema(schema) do
    properties = Map.get(schema || %{}, "properties", %{})

    legacy_citations = %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "properties" => %{
          "label" => %{"type" => "string"},
          "document_id" => %{"type" => "string"},
          "document_reference" => %{"type" => "string"},
          "line_start" => %{"type" => "integer"},
          "line_end" => %{"type" => "integer"},
          "excerpt" => %{"type" => "string"}
        },
        "required" => ["label", "document_id"]
      }
    }

    schema
    |> Map.put("properties", Map.put(properties, "citations", legacy_citations))
  end

  defp print_schema(label, schema) do
    IO.puts("\n#{label}:")
    IO.inspect(schema, pretty: true, limit: :infinity)
  end

  defp save_schema(template, schema) do
    template
    |> ReportSectionTemplate.changeset(%{output_schema: schema})
    |> Repo.update!()
  end

  defp scope! do
    email = System.get_env("LUMAINUS_SAMPLE_USER") || "admin@lumainus.local"

    user =
      Repo.get_by(User, email: email) ||
        raise """
        Could not find user #{email}.
        Run `mix run priv/repo/seeds.exs` or set LUMAINUS_SAMPLE_USER.
        """

    IO.puts("Running as #{email}")
    Scope.for_user(user)
  end

  defp header do
    IO.puts("\n=== ReqLLM Schema Validation Error Reproduction ===\n")

    IO.puts(
      "This script uses Lumainus.AI.SectionRunner to hit the same code path as the /reports UI."
    )
  end

  defp print_module_status do
    IO.puts("\nLoaded modules:")
    IO.puts("  ReqLLM loaded? #{Code.ensure_loaded?(ReqLLM)}")

    IO.puts(
      "  Lumainus.LLM.GeminiClient loaded? #{Code.ensure_loaded?(Lumainus.LLM.GeminiClient)}"
    )

    IO.puts("  Altar loaded? #{Code.ensure_loaded?(Altar)}")
  end
end

Examples.ReqLLMErrorRepro.run()
