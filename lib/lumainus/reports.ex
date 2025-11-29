defmodule Lumainus.Reports do
  @moduledoc """
  Context for managing medical reports, ingestion artifacts, and LLM executions.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Lumainus.Accounts.Scope
  alias Lumainus.Clinical.{Patient, PatientProfile, RecordSets}
  alias Lumainus.Documents
  alias Lumainus.Documents.DocumentUpload
  alias Lumainus.Repo
  alias Lumainus.Reports.SectionRunWorker

  alias Lumainus.Reports.{
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
    t0 = System.monotonic_time(:millisecond)

    tenant_id = tenant_id_from_scope(scope)
    patient = patient_for_scope!(scope, tenant_id, opts)
    t_patient = System.monotonic_time(:millisecond)

    record_set = record_set_for(patient, opts)
    t_record_set = System.monotonic_time(:millisecond)

    template = default_template!(tenant_id)
    t_template = System.monotonic_time(:millisecond)

    documents = list_documents(scope, record_set, include_summary?: false)
    t_documents = System.monotonic_time(:millisecond)

    sections = list_sections_with_runs(scope, record_set)
    t_sections = System.monotonic_time(:millisecond)

    Logger.info(
      "[Reports.workspace] patient=#{t_patient - t0}ms " <>
        "record_set=#{t_record_set - t_patient}ms " <>
        "template=#{t_template - t_record_set}ms " <>
        "documents=#{t_documents - t_template}ms " <>
        "sections=#{t_sections - t_documents}ms " <>
        "total=#{t_sections - t0}ms docs=#{length(documents)} sections=#{length(sections)}"
    )

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

  @doc """
  List documents for a record set, excluding raw_blob to avoid loading multi-MB PDFs.
  Metadata is trimmed to the small subset needed for the UI.
  Does NOT preload parses/chunks - use get_document_with_chunks/1 for that.

  Options:
    * `:include_summary?` - when true, include the stored summary in metadata (defaults to false)
  """
  def list_documents(%Scope{} = scope, record_set, opts \\ []) do
    t0 = System.monotonic_time(:millisecond)
    docs = Documents.list_documents(scope, record_set, opts)
    t1 = System.monotonic_time(:millisecond)

    total_bytes = Enum.reduce(docs, 0, fn d, acc -> acc + (d.byte_size || 0) end)

    Logger.info(
      "[Reports.list_documents] docs=#{length(docs)} bytes=#{total_bytes} time=#{t1 - t0}ms summary?=#{Keyword.get(opts, :include_summary?, false)}"
    )

    docs
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
    t0 = System.monotonic_time(:millisecond)
    template = default_template!(tenant_id_from_scope(scope))

    sections =
      ReportSectionTemplate
      |> where([s], s.template_id == ^template.id)
      |> order_by([s], asc: s.position)
      |> Repo.all()

    t_sections = System.monotonic_time(:millisecond)

    runs_map = latest_section_runs_map(Enum.map(sections, & &1.id), record_set.id)
    t_runs = System.monotonic_time(:millisecond)

    Logger.info(
      "[Reports.list_sections_with_runs] sections=#{length(sections)} " <>
        "sections_query=#{t_sections - t0}ms runs=#{map_size(runs_map)} runs_query=#{t_runs - t_sections}ms " <>
        "total=#{t_runs - t0}ms"
    )

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
               triggered_by_user_id: scope.user && scope.user.id
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
    t0 = System.monotonic_time(:millisecond)

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

    t_ids = System.monotonic_time(:millisecond)

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

    t_runs = System.monotonic_time(:millisecond)

    runs =
      runs
      |> preload_latest_runs()

    t_preload = System.monotonic_time(:millisecond)

    Logger.info(
      "[Reports.latest_section_runs_map] ids=#{length(ids)} latest_ids=#{length(latest_ids)} " <>
        "runs=#{length(runs)} ids_query=#{t_ids - t0}ms runs_query=#{t_runs - t_ids}ms preload=#{t_preload - t_runs}ms total=#{t_preload - t0}ms"
    )

    Enum.into(runs, %{}, fn run -> {run.section_template_id, run} end)
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

    Repo.preload(runs, [:llm_invocation, citations: citations_query])
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
    section_blueprints()
    |> Enum.with_index(1)
    |> Enum.map(fn {blueprint, idx} ->
      instructions = Map.get(blueprint, :instructions)
      schema = Map.get(blueprint, :output_schema) || default_schema()

      %{
        identifier: blueprint.identifier,
        title: blueprint.title,
        prompt_template: section_prompt(blueprint.focus, instructions: instructions),
        output_schema: schema,
        template_id: template_id,
        position: idx * 10
      }
    end)
  end

  defp section_blueprints do
    [
      %{
        identifier: "chief-complaint",
        title: "Chief Complaint",
        focus: "the patient's primary reason for presentation",
        instructions: """
        - Keep this section to 1-2 sentences written from the patient's voice.
        - Capture onset timing, severity, and precipitating context if documented.
        - Highlight notable quotes or descriptors inside quotation marks.
        """
      },
      %{
        identifier: "history-present-illness",
        title: "History of Present Illness (HPI)",
        focus: "a chronological narrative of the presenting problem",
        instructions: """
        - Organize paragraphs by timeline: onset, progression, current status.
        - Mention alleviating/exacerbating factors plus associated ROS findings.
        - Call out pertinent negatives inline (e.g., \"denies syncope\").
        """
      },
      %{
        identifier: "past-history",
        title: "Past History",
        focus: "medical, surgical, and social history summaries",
        instructions: """
        - Create subheadings for Medical History, Surgical History, and Social History.
        - Use bullet lists under each subheading; include dates if available.
        - Social History should mention marital status, tobacco/alcohol/drugs, and occupation when documented.
        """
      },
      %{
        identifier: "medications",
        title: "Medications",
        focus: "current medications, doses, and adherence notes",
        instructions: """
        - Present as a bullet list with medication name, dose, route, and frequency.
        - Note recent changes, held meds, or adherence concerns in italics.
        - Include OTC and supplements if present.
        """
      },
      %{
        identifier: "physical-exam-history",
        title: "Past Physical Exam Findings",
        focus: "historical exam findings and vitals trends",
        instructions: """
        - Group content by system (Cardiovascular, Pulmonary, Neuro, etc.) with subheadings.
        - Highlight abnormal findings first, then list reassuring normals.
        - Include notable vital trends with dates.
        """
      },
      %{
        identifier: "review-of-systems",
        title: "Review of Systems",
        focus: "prior documented ROS results",
        instructions: """
        - Use a table or bullet list grouped by system.
        - For each system, list positives first then key negatives.
        - Limit to items explicitly mentioned in the source documents.
        """
      },
      %{
        identifier: "lab-review",
        title: "Laboratory Review",
        focus: "all relevant laboratory data and trends",
        instructions: """
        - Provide a markdown table with columns: Test, Value & Units, Reference/Flag, Date or Trend.
        - Call out abnormal values with **bold** flags or text.
        - Follow the table with 1-2 sentences interpreting the trends.
        """
      },
      %{
        identifier: "imaging-review",
        title: "Imaging Review",
        focus: "radiology, cardiology, and other imaging summaries",
        instructions: """
        - List each study with modality and date.
        - Summarize impressions plus key measurements (e.g., EF, stenosis %).
        - Note whether follow-up imaging is pending.
        """
      },
      %{
        identifier: "pathology-review",
        title: "Pathology Review",
        focus: "biopsy and pathology results relevant to the case",
        instructions: """
        - Include specimen site, diagnosis, grade/stage markers, and critical molecular findings.
        - Mention when pathology is pending or inconclusive.
        - Tie findings to treatment implications when evident.
        """
      },
      %{
        identifier: "assessment",
        title: "Assessment",
        focus: "synthesis of clinical problems with evidence",
        instructions: """
        - Use a numbered list, one problem per number ordered by priority.
        - Each entry should include 1-2 sentences referencing supporting data with citations.
        - Note current status/severity and clinical uncertainty if present.
        """
      },
      %{
        identifier: "plan",
        title: "Plan",
        focus: "recommended management steps for each assessed problem",
        instructions: """
        - Mirror the numbering from the Assessment section when possible.
        - Detail medications, procedures, monitoring, patient education, and contingency plans.
        - Include follow-up steps and responsible teams.
        """
      }
    ]
  end

  defp default_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "summary" => %{"type" => "string"},
        "markdown" => %{"type" => "string"},
        "citations" => %{
          "type" => "array",
          "description" => "List of citations with label and document_id"
        }
      },
      "required" => ["title", "summary", "markdown", "citations"]
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

  defp section_prompt(focus, opts) do
    instructions_block =
      opts
      |> Keyword.get(:instructions)
      |> case do
        nil ->
          ""

        text ->
          trimmed = String.trim(text)

          """

          Clinical formatting guidance:
          #{trimmed}
          """
      end

    """
    You are drafting the <%= section_title %> portion of a cardiology report focused on #{focus}.
    Patient: <%= patient.full_name %> (MRN <%= patient.mrn %>, DOB <%= patient.date_of_birth %>)

    Cite source evidence using the document IDs below. Inline citations must use the mock ID (e.g., [doc-101])
    and each citation entry in the structured JSON output must include the matching `document_id` value.

    #{instructions_block}

    Document reference table:
    <%= for doc <- documents do %>
    - <%= doc["mock_id"] || doc["label"] %>: Document ID <%= doc["id"] %> · <%= doc["summary"] %>
    <% end %>

    Summaries:
    <%= documents_summary %>

    Source content:
    <%= documents_text %>

    Return JSON that matches the provided schema with keys `title`, `summary`, `markdown`, and `citations`.
    The markdown must include inline citations matching `[mock_id]`. Each citation entry must provide
    `label`, `document_id`, `document_reference`, `line_start`, `line_end`, and a short `excerpt`.
    """
  end
end
