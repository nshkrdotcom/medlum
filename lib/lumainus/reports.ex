defmodule Lumainus.Reports do
  @moduledoc """
  Context for managing medical reports, ingestion artifacts, and LLM executions.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Lumainus.Accounts.Scope
  alias Lumainus.AI.SectionRunner
  alias Lumainus.Clinical.{Patient, PatientProfile}
  alias Lumainus.Documents.DocumentUpload
  alias Lumainus.Repo

  alias Lumainus.Reports.{
    Report,
    ReportRun,
    ReportSectionRun,
    ReportSectionTemplate,
    ReportTemplate
  }

  alias Lumainus.Tenancy.Tenant

  def bootstrap_workspace!(%Scope{} = scope) do
    tenant_id = tenant_id_from_scope(scope)

    Repo.transaction(fn ->
      patient = ensure_patient!(tenant_id)
      ensure_template!(tenant_id)
      patient
    end)
  end

  def workspace(%Scope{} = scope) do
    tenant_id = tenant_id_from_scope(scope)

    %{
      patient: default_patient!(tenant_id),
      template: default_template!(tenant_id),
      documents: list_documents(scope),
      sections: list_sections_with_runs(scope)
    }
  end

  def default_template_for_scope(%Scope{} = scope) do
    default_template!(tenant_id_from_scope(scope))
  end

  def get_template!(id) do
    ReportTemplate
    |> Repo.get!(id)
    |> Repo.preload(:sections)
  end

  def ingestion_prompt(%ReportTemplate{} = template) do
    template.ingestion_prompt_template || default_ingestion_prompt()
  end

  def update_section_prompt(%ReportSectionTemplate{} = section, attrs) do
    section
    |> ReportSectionTemplate.changeset(attrs)
    |> Repo.update()
  end

  def update_ingestion_prompt(%ReportTemplate{} = template, attrs) do
    template
    |> ReportTemplate.changeset(attrs)
    |> Repo.update()
  end

  def list_documents(%Scope{} = scope) do
    DocumentUpload
    |> where([d], d.tenant_id == ^tenant_id_from_scope(scope))
    |> order_by([d], asc: d.inserted_at)
    |> preload(:parses)
    |> Repo.all()
  end

  def list_sections_with_runs(%Scope{} = scope) do
    template = default_template!(tenant_id_from_scope(scope))

    sections =
      ReportSectionTemplate
      |> where([s], s.template_id == ^template.id)
      |> order_by([s], asc: s.position)
      |> Repo.all()

    runs_map = latest_section_runs_map(Enum.map(sections, & &1.id))

    Enum.map(sections, fn section ->
      %{section: section, latest_run: Map.get(runs_map, section.id)}
    end)
  end

  def run_sections(%Scope{} = scope, patient, template, section_ids, opts \\ []) do
    tenant_id = tenant_id_from_scope(scope)
    documents = list_documents(scope)
    ids = normalize_section_ids(section_ids)

    sections =
      ReportSectionTemplate
      |> where([s], s.template_id == ^template.id and s.id in ^ids)
      |> order_by([s], asc: s.position)
      |> Repo.all()

    Repo.transaction(fn ->
      run =
        %ReportRun{}
        |> ReportRun.changeset(%{
          tenant_id: tenant_id,
          patient_id: patient.id,
          template_id: template.id,
          run_type: run_type_for(sections, template),
          status: "running",
          started_at: DateTime.utc_now(:second),
          triggered_by_user_id: scope.user && scope.user.id
        })
        |> Repo.insert!()

      Enum.each(sections, fn section ->
        SectionRunner.run_section(scope, run, section, patient, documents, opts)
      end)

      Repo.update!(
        Changeset.change(run, status: "completed", finished_at: DateTime.utc_now(:second))
      )
    end)
  end

  def last_published_report(%Scope{} = scope) do
    Report
    |> where([r], r.tenant_id == ^tenant_id_from_scope(scope))
    |> order_by([r], desc: r.published_at)
    |> limit(1)
    |> Repo.one()
  end

  defp normalize_section_ids(section_ids) do
    Enum.map(section_ids, fn
      %ReportSectionTemplate{id: id} -> id
      id when is_binary(id) -> UUID.cast!(id)
      id -> UUID.cast!(to_string(id))
    end)
  end

  defp run_type_for(sections, template) do
    if length(sections) == section_count(template) do
      "full"
    else
      "section"
    end
  end

  defp section_count(template) do
    ReportSectionTemplate
    |> where([s], s.template_id == ^template.id)
    |> select([s], count(s.id))
    |> Repo.one()
  end

  defp latest_section_runs_map([]), do: %{}

  defp latest_section_runs_map(section_ids) do
    ReportSectionRun
    |> where([sr], sr.section_template_id in ^section_ids)
    |> order_by([sr], desc: sr.inserted_at)
    |> preload([:llm_invocation, citations: [:document]])
    |> Repo.all()
    |> Enum.reduce(%{}, fn run, acc ->
      Map.put_new(acc, run.section_template_id, run)
    end)
  end

  defp tenant_id_from_scope(%Scope{tenant_id: tenant_id}) when not is_nil(tenant_id),
    do: tenant_id

  defp tenant_id_from_scope(_scope) do
    Tenant
    |> select([t], t.id)
    |> limit(1)
    |> Repo.one!()
  end

  defp default_patient!(tenant_id) do
    Patient
    |> where([p], p.tenant_id == ^tenant_id)
    |> order_by([p], asc: p.inserted_at)
    |> preload(:current_profile)
    |> Repo.one!()
  end

  defp default_template!(tenant_id) do
    ReportTemplate
    |> where([t], t.tenant_id == ^tenant_id)
    |> order_by([t], asc: t.inserted_at)
    |> preload(:sections)
    |> Repo.one!()
  end

  defp ensure_patient!(tenant_id) do
    case Patient |> where([p], p.tenant_id == ^tenant_id) |> Repo.one() do
      nil ->
        {:ok, patient} =
          %Patient{}
          |> Patient.changeset(%{tenant_id: tenant_id, patient_key: "default"})
          |> Repo.insert()

        {:ok, profile} =
          %PatientProfile{}
          |> PatientProfile.changeset(%{
            patient_id: patient.id,
            structured_metadata: %{},
            effective_at: DateTime.utc_now(:second)
          })
          |> Repo.insert()

        patient =
          patient
          |> Changeset.change(current_profile_id: profile.id)
          |> Repo.update!()

        Repo.preload(patient, :current_profile)

      patient ->
        Repo.preload(patient, :current_profile)
    end
  end

  defp ensure_template!(tenant_id) do
    case Repo.get_by(ReportTemplate, tenant_id: tenant_id, slug: "cardiology-primary") do
      nil ->
        template =
          %ReportTemplate{}
          |> ReportTemplate.changeset(%{
            tenant_id: tenant_id,
            name: "Cardiology Intake",
            slug: "cardiology-primary",
            description: "LLM-driven cardiology report",
            default_prompt_options: %{},
            ingestion_prompt_template: default_ingestion_prompt()
          })
          |> Repo.insert!()

        default_sections(template.id)
        |> Enum.with_index()
        |> Enum.each(fn {section_attrs, idx} ->
          %ReportSectionTemplate{}
          |> ReportSectionTemplate.changeset(
            Map.merge(section_attrs, %{position: idx * 10, template_id: template.id})
          )
          |> Repo.insert!()
        end)

        template

      template ->
        template
    end
  end

  defp default_sections(template_id) do
    [
      %{
        identifier: "chief-complaint",
        title: "Chief Complaint & History",
        prompt_template: section_prompt("Chief complaint and history of present illness"),
        output_schema: default_schema(),
        template_id: template_id
      },
      %{
        identifier: "diagnostics",
        title: "Diagnostics Overview",
        prompt_template: section_prompt("Diagnostics, labs, and imaging findings"),
        output_schema: default_schema(),
        template_id: template_id
      },
      %{
        identifier: "assessment-plan",
        title: "Assessment & Plan",
        prompt_template: section_prompt("Assessment and plan with inline citations"),
        output_schema: default_schema(),
        template_id: template_id
      }
    ]
  end

  defp default_schema do
    %{
      "fields" => [
        %{"name" => "title", "type" => "string", "required" => true},
        %{"name" => "summary", "type" => "string", "required" => true},
        %{"name" => "markdown", "type" => "string", "required" => true},
        %{
          "name" => "citations",
          "type" => "list",
          "required" => true,
          "items" => %{
            "type" => "map",
            "fields" => [
              %{"name" => "label", "type" => "string", "required" => true},
              %{"name" => "document_reference", "type" => "string", "required" => true}
            ]
          }
        }
      ]
    }
  end

  defp default_ingestion_prompt do
    """
    You convert uploaded medical PDFs into structured markdown summaries.

    - Read all textual content and preserve its order.
    - Emit markdown with headings (##) for major sections you detect.
    - Keep bullet lists when possible.
    - Extract patient name and MRN if available. If missing, return "Unknown".
    - Capture a short summary paragraph (2-3 sentences) highlighting key facts.
    - Do not include commentary about being an AI.
    """
  end

  defp section_prompt(focus) do
    """
    You are drafting the <%= section_title %> portion of a cardiology report focused on #{focus}.
    Patient: <%= patient.full_name %> (MRN <%= patient.mrn %>, DOB <%= patient.date_of_birth %>)

    Use the summarized evidence below. Cite inline using [doc-###] markers that map to the mock IDs.

    Summaries:
    <%= documents_summary %>

    Source content:
    <%= documents_text %>

    Return markdown with headings, bullet points, and inline citations.
    """
  end
end
