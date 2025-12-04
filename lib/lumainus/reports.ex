defmodule Lumainus.Reports do
  @moduledoc """
  Context for managing medical reports, ingestion artifacts, and LLM executions.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Lumainus.Accounts.Scope
  alias Lumainus.Clinical.{Patient, PatientProfile, RecordSets}
  alias Lumainus.AI.LlmInvocation
  alias Lumainus.Documents
  alias Lumainus.Documents.DocumentUpload
  alias Lumainus.Repo
  alias Lumainus.Reports.SectionRunWorker

  alias Lumainus.Reports.{
    Blueprints,
    Report,
    ReportRun,
    ReportSectionCitation,
    ReportSectionRun,
    ReportSectionTemplate,
    ReportTemplate
  }

  alias Lumainus.Tenancy.Tenant
  alias Oban
  alias Phoenix.PubSub
  require Logger

  @run_topic_prefix "report-run"

  def bootstrap_workspace!(%Scope{} = scope) do
    tenant_id = tenant_id_from_scope(scope)

    Repo.transaction(fn ->
      profile_query = profile_query_without_metadata()
      patient = ensure_patient_for_scope!(scope, tenant_id, profile_query)
      ensure_template!(tenant_id)
      patient
    end)
  end

  def workspace(%Scope{} = scope, opts \\ []) do
    tenant_id = tenant_id_from_scope(scope)
    patient = patient_for_scope!(scope, tenant_id, opts)
    record_set = record_set_for(patient, opts)
    template = default_template!(tenant_id)
    documents = list_documents(scope, record_set, include_summary?: false)
    sections = list_sections_with_runs(scope, record_set)

    %{
      patient: patient,
      record_set: record_set,
      template: template,
      documents: documents,
      sections: sections
    }
  end

  def list_patients_for_scope(%Scope{} = scope) do
    tenant_id = tenant_id_from_scope(scope)

    # Preload profile WITHOUT structured_metadata (can be huge - contains full document text)
    profile_fields =
      Lumainus.Clinical.PatientProfile.__schema__(:fields)
      |> Enum.reject(&(&1 == :structured_metadata))

    profile_query =
      from(pp in Lumainus.Clinical.PatientProfile,
        select: struct(pp, ^profile_fields)
      )

    Patient
    |> where([p], p.tenant_id == ^tenant_id)
    |> maybe_filter_patients_for_user(scope.user)
    |> order_by([p], asc: p.inserted_at)
    |> preload(current_profile: ^profile_query)
    |> Repo.all()
  end

  def create_patient_for_scope(%Scope{} = scope, attrs \\ %{}) do
    tenant_id = tenant_id_from_scope(scope)

    attrs =
      attrs
      |> Map.new()
      |> maybe_put_created_by(scope.user)

    create_patient(tenant_id, attrs)
  end

  def subscribe_to_section_runs(record_set_id) when is_binary(record_set_id) do
    PubSub.subscribe(LumainusWeb.PubSub, run_topic(record_set_id))
  end

  def notify_section_run_update(record_set_id) when is_binary(record_set_id) do
    PubSub.broadcast(
      LumainusWeb.PubSub,
      run_topic(record_set_id),
      {:section_run_updated, record_set_id}
    )
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
    template.ingestion_prompt_template || Blueprints.default_ingestion_prompt()
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

  @doc """
  List documents for a record set, excluding raw_blob to avoid loading multi-MB PDFs.
  Metadata is trimmed to the small subset needed for the UI.
  Does NOT preload parses/chunks - use get_document_with_chunks/1 for that.

  Options:
    * `:include_summary?` - when true, include the stored summary in metadata (defaults to false)
  """
  def list_documents(%Scope{} = scope, record_set, opts \\ []) do
    Documents.list_documents(scope, record_set, opts)
  end

  @doc """
  List documents with parses and chunks preloaded for citation-aware pipelines (LLM, reports).
  Excludes raw_blob to avoid loading multi-MB PDF binaries.
  """
  def list_documents_with_chunks(%Scope{} = scope, record_set) do
    fields =
      DocumentUpload.__schema__(:fields)
      |> Enum.reject(&(&1 == :raw_blob))

    DocumentUpload
    |> where([d], d.tenant_id == ^tenant_id_from_scope(scope))
    |> where([d], d.record_set_id == ^record_set.id)
    |> order_by([d], desc: d.inserted_at)
    |> preload(parses: :chunks)
    |> select([d], struct(d, ^fields))
    |> Repo.all()
  end

  @doc """
  Get a document with its parses and chunks preloaded.
  Use this when you need the actual content chunks.
  """
  def get_document_with_chunks(document_id) when is_binary(document_id) do
    DocumentUpload
    |> where([d], d.id == ^document_id)
    |> Repo.one()
    |> Repo.preload(parses: :chunks)
  end

  @doc """
  Load document content (raw_blob and parsed_text) for a specific document.
  Content is truncated for safety; see Lumainus.Documents.get_document_content/2.
  """
  def get_document_content(document_id, opts \\ []) when is_binary(document_id) do
    Documents.get_document_content(document_id, opts)
  end

  defp document_ids_for(%Scope{} = scope, record_set) do
    DocumentUpload
    |> where([d], d.tenant_id == ^tenant_id_from_scope(scope))
    |> where([d], d.record_set_id == ^record_set.id)
    |> select([d], d.id)
    |> Repo.all()
  end

  def list_sections_with_runs(%Scope{} = scope, record_set) do
    template = default_template!(tenant_id_from_scope(scope))

    sections =
      ReportSectionTemplate
      |> where([s], s.template_id == ^template.id)
      |> order_by([s], asc: s.position)
      |> Repo.all()

    runs_map = latest_section_runs_map(Enum.map(sections, & &1.id), record_set.id)

    Enum.map(sections, fn section ->
      %{section: section, latest_run: Map.get(runs_map, section.id)}
    end)
  end

  def list_runs_for_record_set(%Scope{} = scope, record_set, opts \\ []) do
    limit = opts[:limit] || 5

    ReportRun
    |> where([r], r.tenant_id == ^tenant_id_from_scope(scope))
    |> where([r], r.record_set_id == ^record_set.id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def latest_runs_for_record_sets(%Scope{} = scope, record_sets) do
    tenant_id = tenant_id_from_scope(scope)
    ids = Enum.map(record_sets, & &1.id)

    case ids do
      [] ->
        %{}

      record_set_ids ->
        ReportRun
        |> where([r], r.tenant_id == ^tenant_id)
        |> where([r], r.record_set_id in ^record_set_ids)
        |> order_by([r], desc: r.inserted_at)
        |> Repo.all()
        |> Enum.reduce(%{}, fn run, acc ->
          Map.put_new(acc, run.record_set_id, run)
        end)
    end
  end

  def run_sections(%Scope{} = scope, patient, record_set, template, section_ids, opts \\ []) do
    tenant_id = tenant_id_from_scope(scope)
    ids = normalize_section_ids(section_ids)
    document_ids = document_ids_for(scope, record_set)

    now = DateTime.utc_now(:second)
    timeout_minutes = Keyword.get(opts, :timeout_minutes, 30)
    timeout_at = DateTime.add(now, timeout_minutes, :minute)

    sections =
      ReportSectionTemplate
      |> where([s], s.template_id == ^template.id and s.id in ^ids)
      |> order_by([s], asc: s.position)
      |> Repo.all()

    case Repo.transaction(fn ->
           run =
             %ReportRun{}
             |> ReportRun.changeset(%{
               tenant_id: tenant_id,
               patient_id: patient.id,
               record_set_id: record_set.id,
               template_id: template.id,
               run_type: run_type_for(sections, template),
               status: "queued",
               triggered_by_user_id: scope.user && scope.user.id,
               timeout_at: timeout_at,
               last_activity_at: now
             })
             |> Repo.insert!()

           section_runs =
             Enum.map(sections, fn section ->
               %ReportSectionRun{}
               |> ReportSectionRun.changeset(%{
                 report_run_id: run.id,
                 section_template_id: section.id,
                 status: "queued",
                 prompt_inputs: %{
                   "document_ids" => document_ids,
                   "record_set_id" => record_set.id,
                   "patient_profile_id" => patient.current_profile_id
                 }
               })
               |> Repo.insert!()
             end)

           {run, section_runs}
         end) do
      {:ok, {run, section_runs}} ->
        case enqueue_section_runs(run, section_runs, opts) do
          :ok ->
            notify_section_run_update(run.record_set_id)
            {:ok, run}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue_section_runs(run, section_runs, opts) do
    worker = Keyword.get(opts, :worker, SectionRunWorker)

    Enum.reduce_while(section_runs, :ok, fn section_run, _acc ->
      case worker.new(%{"section_run_id" => section_run.id}) |> Oban.insert() do
        {:ok, _job} ->
          {:cont, :ok}

        {:error, reason} ->
          mark_section_run_failed(section_run, reason)

          Repo.update!(
            Changeset.change(run, %{
              status: "error",
              finished_at: DateTime.utc_now(:second)
            })
          )

          {:halt, {:error, reason}}
      end
    end)
  end

  defp mark_section_run_failed(section_run, reason) do
    # Log error instead of persisting to DB
    require Logger

    Logger.error("""
    [Reports] Section run failed: #{section_run.id}
    Reason: #{inspect(reason)}
    """)

    # Mark as pending (not error) so it can be retried
    section_run
    |> Changeset.change(%{status: "pending"})
    |> Repo.update!()
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

  defp latest_section_runs_map([], _record_set_id), do: %{}

  defp latest_section_runs_map(section_ids, record_set_id) do
    ids =
      try do
        Enum.to_list(section_ids)
      rescue
        _ ->
          Logger.error(
            "[Reports] latest_section_runs_map received non-enumerable section_ids: #{inspect(section_ids)}"
          )

          []
      end

    latest_ids =
      ReportSectionRun
      |> join(:inner, [sr], r in ReportRun, on: r.id == sr.report_run_id)
      |> where([sr, r], sr.section_template_id in ^ids and r.record_set_id == ^record_set_id)
      |> windows([sr],
        w: [partition_by: sr.section_template_id, order_by: [desc: sr.inserted_at]]
      )
      |> select([sr], %{id: sr.id, row_num: row_number() |> over(:w)})
      |> subquery()
      |> where([t], t.row_num == 1)
      |> select([t], t.id)
      |> Repo.all()

    runs =
      ReportSectionRun
      |> where([sr], sr.id in ^latest_ids)
      |> select([sr], %ReportSectionRun{
        id: sr.id,
        section_template_id: sr.section_template_id,
        status: sr.status,
        output_markdown: sr.output_markdown,
        inline_citations: sr.inline_citations,
        inserted_at: sr.inserted_at,
        updated_at: sr.updated_at,
        llm_invocation_id: sr.llm_invocation_id,
        report_run_id: sr.report_run_id
      })
      |> Repo.all()

    preload_latest_runs(runs)
    |> Enum.into(%{}, fn run -> {run.section_template_id, run} end)
  end

  defp preload_latest_runs(runs) do
    doc_query =
      from(d in DocumentUpload,
        select: %DocumentUpload{
          id: d.id,
          filename: d.filename,
          byte_size: d.byte_size,
          metadata: d.metadata
        }
      )

    citations_query =
      from(c in ReportSectionCitation,
        preload: [document: ^doc_query]
      )

    llm_shallow_query =
      from(l in LlmInvocation,
        select: %LlmInvocation{
          id: l.id,
          provider: l.provider,
          model: l.model,
          status: l.status,
          error: l.error,
          usage: l.usage,
          req_duration_ms: l.req_duration_ms,
          request_id: l.request_id,
          tenant_id: l.tenant_id,
          inserted_at: l.inserted_at,
          updated_at: l.updated_at
        }
      )

    Repo.preload(runs, llm_invocation: llm_shallow_query, citations: citations_query)
  end

  defp maybe_filter_patients_for_user(query, nil), do: query

  defp maybe_filter_patients_for_user(query, user) do
    where(query, [p], p.created_by_user_id == ^user.id)
  end

  defp maybe_put_created_by(attrs, nil), do: attrs
  defp maybe_put_created_by(attrs, user), do: Map.put_new(attrs, :created_by_user_id, user.id)

  defp tenant_id_from_scope(%Scope{tenant_id: tenant_id}) when not is_nil(tenant_id),
    do: tenant_id

  defp tenant_id_from_scope(_scope) do
    Tenant
    |> select([t], t.id)
    |> limit(1)
    |> Repo.one!()
  end

  defp run_topic(record_set_id), do: "#{@run_topic_prefix}:#{record_set_id}"

  defp patient_for_scope!(%Scope{} = scope, tenant_id, opts) do
    # Exclude structured_metadata from profile - can be huge (contains full document text)
    profile_query = profile_query_without_metadata()

    case opts[:patient_id] do
      nil ->
        ensure_patient_for_scope!(scope, tenant_id, profile_query)

      patient_id ->
        Patient
        |> where([p], p.tenant_id == ^tenant_id and p.id == ^patient_id)
        |> maybe_filter_patients_for_user(scope.user)
        |> preload(current_profile: ^profile_query)
        |> Repo.one!()
    end
  end

  defp profile_query_without_metadata do
    profile_fields =
      Lumainus.Clinical.PatientProfile.__schema__(:fields)
      |> Enum.reject(&(&1 == :structured_metadata))

    from(pp in Lumainus.Clinical.PatientProfile, select: struct(pp, ^profile_fields))
  end

  defp record_set_for(patient, opts) do
    case opts[:record_set_id] do
      nil ->
        RecordSets.primary_for_patient(patient)

      id ->
        case record_set_for_patient(patient, id) do
          nil -> RecordSets.primary_for_patient(patient)
          record_set -> record_set
        end
    end
  end

  defp ensure_patient_for_scope!(%Scope{user: nil}, tenant_id, _profile_query),
    do: ensure_patient!(tenant_id)

  defp ensure_patient_for_scope!(%Scope{user: user}, tenant_id, profile_query) do
    Patient
    |> where([p], p.tenant_id == ^tenant_id and p.created_by_user_id == ^user.id)
    |> order_by([p], asc: p.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil ->
        case create_patient(tenant_id, %{created_by_user_id: user.id}) do
          {:ok, patient} ->
            patient

          {:error, changeset} ->
            raise "failed to create patient for user: #{inspect(changeset.errors)}"
        end

      patient ->
        Repo.preload(patient, current_profile: profile_query)
    end
  end

  defp create_patient(tenant_id, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.put_new(:tenant_id, tenant_id)
      |> Map.put_new(:patient_key, UUID.generate())
      |> Map.put_new(:status, "active")

    with {:ok, patient} <-
           %Patient{}
           |> Patient.changeset(attrs)
           |> Repo.insert(),
         {:ok, profile} <-
           %PatientProfile{}
           |> PatientProfile.changeset(%{
             patient_id: patient.id,
             structured_metadata: %{},
             effective_at: DateTime.utc_now(:second)
           })
           |> Repo.insert(),
         {:ok, patient} <-
           patient
           |> Changeset.change(current_profile_id: profile.id)
           |> Repo.update() do
      {:ok, Repo.preload(patient, :current_profile)}
    else
      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp record_set_for_patient(patient, id) do
    RecordSets.list_for_patient(patient)
    |> Enum.find(&(&1.id == id))
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
        case create_patient(tenant_id) do
          {:ok, patient} ->
            patient

          {:error, changeset} ->
            raise "failed to create default patient: #{inspect(changeset.errors)}"
        end

      patient ->
        Repo.preload(patient, :current_profile)
    end
  end

  defp ensure_template!(tenant_id) do
    case Repo.get_by(ReportTemplate, tenant_id: tenant_id, slug: "cardiology-primary") do
      nil ->
        template_attrs = Blueprints.default_template_attrs()

        template =
          %ReportTemplate{}
          |> ReportTemplate.changeset(%{
            tenant_id: tenant_id,
            name: template_attrs.name,
            slug: template_attrs.slug,
            description: template_attrs.description,
            default_prompt_options: %{},
            ingestion_prompt_template: Blueprints.default_ingestion_prompt(),
            system_prompt: Blueprints.default_system_prompt()
          })
          |> Repo.insert!()

        default_sections(template.id)
        |> Enum.each(fn section_attrs ->
          %ReportSectionTemplate{}
          |> ReportSectionTemplate.changeset(section_attrs)
          |> Repo.insert!()
        end)

        template

      template ->
        template
    end
  end

  @doc false
  def default_sections(template_id) do
    Blueprints.section_blueprints()
    |> Enum.with_index(1)
    |> Enum.map(fn {blueprint, idx} ->
      instructions = Map.get(blueprint, :instructions)
      schema = Map.get(blueprint, :output_schema) || Blueprints.default_output_schema()

      %{
        identifier: blueprint.identifier,
        title: blueprint.title,
        prompt_template: Blueprints.section_prompt(blueprint.focus, instructions: instructions),
        output_schema: schema,
        template_id: template_id,
        position: idx * 10
      }
    end)
  end
end
