defmodule LumainusWeb.ReportsLive do
  use LumainusWeb, :live_view

  alias Ecto.Changeset
  alias Lumainus.Documents
  alias Lumainus.Clinical.{Patients, RecordSets}
  alias Lumainus.Reports
  alias MapSet
  alias Path
  alias Phoenix.LiveView.JS
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    Reports.bootstrap_workspace!(scope)

    socket =
      socket
      |> allow_upload(:documents,
        accept: ~w(.pdf),
        max_entries: 5,
        max_file_size: 25_000_000,
        auto_upload: true,
        progress: &handle_upload_progress/3
      )
      |> load_workspace()

    socket =
      if connected?(socket) do
        Documents.subscribe_to_record_set(socket.assigns.record_set.id)

        assign(
          socket,
          :record_set_subscriptions,
          MapSet.put(socket.assigns.record_set_subscriptions, socket.assigns.record_set.id)
        )
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("select_document", %{"doc-id" => doc_id}, socket) do
    doc_id = to_string(doc_id)
    current = socket.assigns.selected_document

    cond do
      current && to_string(current.id) == doc_id ->
        {:noreply, assign(socket, selected_document: nil)}

      true ->
        doc = Enum.find(socket.assigns.documents, &(to_string(&1.id) == doc_id))
        {:noreply, assign(socket, selected_document: doc)}
    end
  end

  @impl true
  def handle_event("clear_document", _params, socket) do
    {:noreply, assign(socket, selected_document: nil)}
  end

  @impl true
  def handle_event("run_section", %{"section-id" => section_id}, socket) do
    run_sections(socket, [section_id])
  end

  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("run_full_report", _params, socket) do
    section_ids = Enum.map(socket.assigns.sections, & &1.section.id)
    run_sections(socket, section_ids)
  end

  def handle_event("seed_sample_documents", _params, socket) do
    scope = socket.assigns.current_scope

    case Documents.seed_sample_documents(scope, socket.assigns.patient, socket.assigns.record_set) do
      {:ok, :noop} ->
        {:noreply,
         put_flash(socket, :info, "Sample documents already loaded.") |> load_workspace()}

      {:ok, uploads} ->
        {:noreply,
         socket
         |> put_flash(:info, "Loaded #{length(uploads)} sample documents.")
         |> load_workspace()}
    end
  end

  @impl true
  def handle_event("delete_document", %{"doc-id" => doc_id}, socket) do
    scope = socket.assigns.current_scope

    case Documents.delete_upload(scope, doc_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:selected_document, nil)
         |> put_flash(:info, "Document removed.")
         |> load_workspace()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Document no longer exists.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unable to delete: #{inspect(reason)}")}
    end
  end

  def handle_event("open_patient_modal", _params, socket) do
    {:noreply, assign(socket, :patient_modal_open, true)}
  end

  def handle_event("close_patient_modal", _params, socket) do
    {:noreply, assign(socket, :patient_modal_open, false)}
  end

  def handle_event("select_record_set", %{"id" => record_set_id}, socket) do
    {:noreply,
     socket
     |> assign(:patient_modal_open, false)
     |> load_workspace(record_set_id: record_set_id)}
  end

  def handle_event("create_record_set", _params, socket) do
    case RecordSets.create_record_set(socket.assigns.patient) do
      {:ok, record_set} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{record_set.label} created.")
         |> assign(:patient_modal_open, false)
         |> load_workspace(record_set_id: record_set.id)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to create workspace: #{humanize_errors(changeset)}")}
    end
  end

  def handle_event("validate_patient_profile", %{"profile" => params}, socket) do
    form = profile_form(socket.assigns.patient, params, :validate)
    {:noreply, assign(socket, :profile_form, form)}
  end

  def handle_event("save_patient_profile", %{"profile" => params}, socket) do
    case Patients.update_profile(socket.assigns.patient, params) do
      {:ok, _patient} ->
        {:noreply,
         socket
         |> put_flash(:info, "Patient details saved.")
         |> load_workspace()}

      {:error, changeset} ->
        form = profile_form_from_changeset(changeset, :validate)
        {:noreply, assign(socket, :profile_form, form)}
    end
  end

  defp run_sections(socket, section_ids) do
    scope = socket.assigns.current_scope

    case Reports.run_sections(
           scope,
           socket.assigns.patient,
           socket.assigns.record_set,
           socket.assigns.template,
           section_ids
         ) do
      {:ok, _run} ->
        {:noreply, load_workspace(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Report generation failed: #{inspect(reason)}")
         |> load_workspace()}
    end
  end

  defp load_workspace(socket, opts \\ []) do
    scope = socket.assigns.current_scope
    record_set_id = opts[:record_set_id] || socket.assigns[:active_record_set_id]
    workspace = Reports.workspace(scope, record_set_id: record_set_id)
    documents = format_documents(workspace.documents)
    sections = format_sections(workspace.sections)

    running_sections =
      sections
      |> Enum.filter(&(&1.status in ["running", "queued"]))
      |> Enum.map(& &1.section.id)
      |> MapSet.new()

    record_sets = RecordSets.list_for_patient(workspace.patient)
    record_set_latest_runs = Reports.latest_runs_for_record_sets(scope, record_sets)
    recent_runs = Reports.list_runs_for_record_set(scope, workspace.record_set, limit: 5)

    socket =
      socket
      |> assign(:patient, workspace.patient)
      |> assign(:record_set, workspace.record_set)
      |> assign(:template, workspace.template)
      |> assign(:documents, documents)
      |> assign(:sections, sections)
      |> assign(:running_sections, running_sections)
      |> assign(:record_sets, record_sets)
      |> assign(:record_set_latest_runs, record_set_latest_runs)
      |> assign(:recent_runs, recent_runs)
      |> assign(:profile_form, profile_form(workspace.patient))
      |> assign(:active_record_set_id, workspace.record_set.id)
      |> assign_new(:selected_document, fn -> nil end)
      |> assign_new(:patient_modal_open, fn -> false end)
      |> assign_new(:job_subscriptions, fn -> MapSet.new() end)
      |> assign_new(:record_set_subscriptions, fn -> MapSet.new() end)
      |> assign_new(:report_run_subscriptions, fn -> MapSet.new() end)

    socket
    |> maybe_subscribe_record_set(workspace.record_set.id)
    |> maybe_subscribe_report_runs(workspace.record_set.id)
    |> subscribe_to_job_topics()
  end

  @impl true
  def handle_info({:documents_changed, record_set_id}, socket) do
    if socket.assigns.record_set.id == record_set_id do
      {:noreply, load_workspace(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:job_progress, record_set_id, payload}, socket) do
    if socket.assigns.record_set.id == record_set_id do
      updated = update_document_progress(socket.assigns.documents, payload)
      {:noreply, assign(socket, :documents, updated)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:section_run_updated, record_set_id}, socket) do
    if socket.assigns.record_set.id == record_set_id do
      {:noreply, load_workspace(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp handle_upload_progress(:documents, entry, socket) do
    Logger.debug(
      "Upload progress for #{entry.client_name}: #{entry.progress}% (done? #{entry.done?})"
    )

    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          case read_uploaded_file(path, entry) do
            {:ok, payload} ->
              {:ok, {:success, payload}}

            {:error, reason} ->
              {:ok, {:error, reason}}
          end
        end)

      Logger.debug("consume_uploaded_entry returned #{inspect(result)}")
      entry_processed(socket, result)
    else
      {:noreply, socket}
    end
  end

  defp handle_upload_progress(_name, _entry, socket), do: {:noreply, socket}

  defp entry_processed(socket, {:ok, {:success, payload}}) do
    handle_consumed_entry(payload, socket)
  end

  defp entry_processed(socket, {:success, payload}) do
    handle_consumed_entry(payload, socket)
  end

  defp entry_processed(socket, {:ok, {:error, reason}}) do
    {:noreply, put_flash(socket, :error, "Upload failed: #{inspect(reason)}")}
  end

  defp entry_processed(socket, {:error, reason}) do
    {:noreply, put_flash(socket, :error, "Upload failed: #{inspect(reason)}")}
  end

  defp entry_processed(socket, {:postpone, _payload}), do: {:noreply, socket}

  defp entry_processed(socket, _other), do: {:noreply, socket}

  defp handle_consumed_entry(%{binary: binary, meta: meta}, socket) do
    Logger.debug("ReportsLive received upload #{meta.filename} (#{meta.byte_size} bytes)")

    case persist_upload(meta, binary, socket) do
      {:ok, updated_socket} ->
        {:noreply,
         updated_socket
         |> put_flash(:info, "#{meta.filename} queued for ingestion.")
         |> load_workspace()}

      {:duplicate, upload} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{meta.filename} already uploaded on #{format_timestamp(upload.inserted_at)}"
         )
         |> load_workspace(record_set_id: upload.record_set_id)}

      {:error, updated_socket} ->
        {:noreply, updated_socket}
    end
  end

  defp persist_upload(meta, binary, socket) do
    scope = socket.assigns.current_scope
    template = socket.assigns.template
    patient = socket.assigns.patient
    record_set = socket.assigns.record_set

    case Documents.create_upload(scope, patient, record_set, meta, binary) do
      {:ok, upload} ->
        Documents.queue_ingestion(upload, template)
        {:ok, socket}

      {:error, {:duplicate, upload}} ->
        {:duplicate, upload}

      {:error, changeset} ->
        Logger.error("Failed to persist upload #{meta.filename}: #{humanize_errors(changeset)}")

        {:error,
         socket
         |> put_flash(:error, "Unable to save #{meta.filename}: #{humanize_errors(changeset)}")}
    end
  end

  defp read_uploaded_file(path, entry) do
    case File.read(path) do
      {:ok, binary} ->
        upload_meta = %{
          filename: entry.client_name,
          content_type: entry.client_type,
          byte_size: entry.client_size
        }

        {:ok, %{meta: upload_meta, binary: binary}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_documents(documents) do
    documents
    |> Enum.with_index(1)
    |> Enum.map(fn {doc, index} ->
      parse = List.first(doc.parses || [])
      metadata = doc.metadata || %{}
      label = metadata["label"] || Path.rootname(doc.filename)
      summary = metadata["summary"] || "Awaiting ingestion"
      provider = metadata["provider"] || "Unknown source"
      date = metadata["date"] || Calendar.strftime(doc.inserted_at, "%Y-%m-%d")
      ingestion_stage = metadata["ingestion_stage"]
      ingestion_progress = metadata["ingestion_progress"] || 0
      ingestion_message = metadata["ingestion_message"]
      job_id = metadata["ingestion_job_id"]
      status = doc.status || metadata["status"] || ingestion_stage

      %{
        id: doc.id,
        sequence: index,
        filename: doc.filename,
        mock_id: metadata["mock_id"],
        label: label,
        summary: summary,
        provider: provider,
        date: date,
        kind: doc.document_kind,
        cleaned_content: parse && parse.parsed_text,
        raw_content: doc.raw_blob,
        status: status,
        ingestion_stage: ingestion_stage,
        ingestion_progress: ingestion_progress,
        ingestion_message: ingestion_message,
        ingestion_job_id: job_id,
        uploaded_at: doc.inserted_at,
        ingested_at: doc.ingested_at,
        byte_size: doc.byte_size,
        content_type: doc.content_type,
        byte_size_label: format_byte_size(doc.byte_size)
      }
    end)
  end

  defp format_sections(entries) do
    Enum.map(entries, fn %{section: section, latest_run: run} = entry ->
      %{
        section: section,
        last_run: format_run(run),
        status: run_status(entry)
      }
    end)
  end

  defp subscribe_to_job_topics(socket) do
    if connected?(socket) do
      job_ids =
        socket.assigns.documents
        |> Enum.map(& &1.ingestion_job_id)
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()

      new_ids = MapSet.difference(job_ids, socket.assigns.job_subscriptions)

      Enum.each(new_ids, &Documents.subscribe_to_ingestion_job/1)

      assign(socket, :job_subscriptions, MapSet.union(socket.assigns.job_subscriptions, new_ids))
    else
      socket
    end
  end

  defp maybe_subscribe_record_set(socket, record_set_id) do
    if connected?(socket) and
         not MapSet.member?(socket.assigns.record_set_subscriptions, record_set_id) do
      Documents.subscribe_to_record_set(record_set_id)

      assign(
        socket,
        :record_set_subscriptions,
        MapSet.put(socket.assigns.record_set_subscriptions, record_set_id)
      )
    else
      socket
    end
  end

  defp maybe_subscribe_report_runs(socket, record_set_id) do
    if connected?(socket) and
         not MapSet.member?(socket.assigns.report_run_subscriptions, record_set_id) do
      Reports.subscribe_to_section_runs(record_set_id)

      assign(
        socket,
        :report_run_subscriptions,
        MapSet.put(socket.assigns.report_run_subscriptions, record_set_id)
      )
    else
      socket
    end
  end

  defp update_document_progress(documents, payload) do
    upload_id = Map.get(payload, :upload_id) || Map.get(payload, "upload_id")
    stage = Map.get(payload, :stage) || Map.get(payload, "stage")
    progress = Map.get(payload, :progress) || Map.get(payload, "progress")
    message = Map.get(payload, :last_message) || Map.get(payload, "last_message")
    job_id = Map.get(payload, :job_id) || Map.get(payload, "job_id")

    Enum.map(documents, fn doc ->
      if doc.id == upload_id do
        doc
        |> Map.put(:status, stage || doc.status)
        |> Map.put(:ingestion_stage, stage || doc.ingestion_stage)
        |> Map.put(:ingestion_progress, progress || doc.ingestion_progress)
        |> Map.put(:ingestion_message, message || doc.ingestion_message)
        |> Map.put(:ingestion_job_id, job_id || doc.ingestion_job_id)
      else
        doc
      end
    end)
  end

  defp format_byte_size(nil), do: "—"

  defp format_byte_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_048_576 ->
        value = bytes / 1_048_576
        :erlang.float_to_binary(value, decimals: 1) <> " MB"

      bytes >= 1024 ->
        value = bytes / 1024
        :erlang.float_to_binary(value, decimals: 1) <> " KB"

      true ->
        Integer.to_string(bytes) <> " B"
    end
  end

  defp format_run(nil), do: nil

  defp format_run(run) do
    %{
      id: run.id,
      status: run.status,
      output_markdown: run.output_markdown,
      updated_at: run.updated_at,
      citations: Enum.map(run.citations || [], &format_citation/1),
      error: run.error
    }
  end

  defp format_citation(citation) do
    %{
      id: citation.id,
      label: citation.citation_label,
      document_id: citation.document_id
    }
  end

  defp run_status(%{latest_run: nil}), do: "not_started"
  defp run_status(%{latest_run: %{status: status}}), do: status

  defp document_status(%{ingestion_stage: stage, status: status}), do: stage || status
  defp document_status(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      .reports-shell {
        min-height: calc(100vh - 96px);
        background: #f8fafc;
        padding: 32px;
        display: flex;
        flex-direction: column;
        gap: 24px;
      }

      .patient-banner {
        background: #fff;
        border: 1px solid #e2e8f0;
        border-radius: 16px;
        padding: 24px;
        display: flex;
        flex-wrap: wrap;
        gap: 16px;
        justify-content: space-between;
      }

      .patient-actions {
        display: flex;
        align-items: center;
        gap: 8px;
      }

      .patient-actions .manage-btn {
        border: 1px solid #cbd5e1;
        color: #0f172a;
        background: linear-gradient(135deg, #f8fbff, #eef4ff);
        border-radius: 999px;
        padding: 6px 16px;
        font-size: 12px;
        font-weight: 600;
        box-shadow: 0 4px 10px rgba(15, 23, 42, 0.08);
        transition: transform 0.2s ease, box-shadow 0.2s ease, background 0.2s ease;
      }

      .patient-actions .manage-btn:hover,
      .patient-actions .manage-btn:focus-visible {
        background: linear-gradient(135deg, #e0ecff, #f3f8ff);
        box-shadow: 0 6px 14px rgba(15, 23, 42, 0.12);
        transform: translateY(-1px);
      }

      .reports-body {
        display: grid;
        grid-template-columns: 320px 1fr;
        gap: 24px;
      }

      .documents-panel {
        background: #fff;
        border: 1px solid #e2e8f0;
        border-radius: 16px;
        padding: 16px;
        display: flex;
        flex-direction: column;
        gap: 12px;
        height: calc(100vh - 240px);
      }

      .document-list {
        flex: 1;
        overflow-y: auto;
        padding-right: 4px;
        display: flex;
        flex-direction: column;
        gap: 8px;
      }

      .document-card {
        border: 1px solid #e2e8f0;
        border-radius: 12px;
        padding: 12px;
        text-align: left;
        transition: border-color 0.2s ease;
        background: #fff;
      }

      .document-card.active {
        border-color: #2563eb;
        background: #f8fbff;
      }

      .doc-detail-meta {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
        gap: 12px;
        margin-top: 12px;
        font-size: 11px;
        color: #475569;
      }

      .doc-detail-meta strong {
        display: block;
        font-size: 13px;
        color: #0f172a;
      }

      .doc-detail-actions {
        display: flex;
        gap: 8px;
        align-items: center;
      }

      .modal-backdrop {
        position: fixed;
        inset: 0;
        background: rgba(15, 23, 42, 0.45);
        display: flex;
        align-items: center;
        justify-content: center;
        z-index: 50;
      }

      .patient-modal {
        width: min(960px, 95vw);
        background: #fff;
        border-radius: 16px;
        padding: 24px;
        border: 1px solid #e2e8f0;
        box-shadow: 0 20px 40px rgba(15, 23, 42, 0.25);
        display: flex;
        flex-direction: column;
        gap: 16px;
        color: #0f172a;
      }

      .patient-modal .input,
      .patient-modal .textarea,
      .patient-modal .select {
        background: #fff !important;
        color: #0f172a;
        border-color: #e2e8f0;
      }

      .patient-modal .input::placeholder,
      .patient-modal .textarea::placeholder {
        color: #94a3b8;
      }

      .patient-modal .label {
        color: #475569;
        font-weight: 600;
      }

      .patient-modal-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
        gap: 20px;
      }

      .modal-column {
        display: flex;
        flex-direction: column;
        gap: 16px;
      }

      .modal-panel {
        border: 1px solid #e2e8f0;
        border-radius: 14px;
        padding: 16px;
        background: #fdfefe;
        display: flex;
        flex-direction: column;
        gap: 12px;
      }

      .modal-panel h3 {
        margin: 0;
        font-size: 13px;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        color: #94a3b8;
      }

      .recent-runs {
        display: flex;
        flex-direction: column;
        gap: 8px;
      }

      .recent-run {
        border: 1px solid #e2e8f0;
        border-radius: 12px;
        padding: 12px;
        background: #fff;
      }

      .recent-run header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        font-size: 13px;
        color: #0f172a;
      }

      .recent-run p {
        margin: 4px 0 0 0;
        font-size: 12px;
        color: #64748b;
      }

      .status-pill {
        font-size: 11px;
        padding: 2px 10px;
        border-radius: 999px;
        border: 1px solid #cbd5f5;
        background: #eff6ff;
        color: #1d4ed8;
      }

      .status-pill[data-status="running"] {
        border-color: #fde68a;
        background: #fffbeb;
        color: #b45309;
      }

      .status-pill[data-status="error"] {
        border-color: #fecdd3;
        background: #fef2f2;
        color: #b91c1c;
      }

      .prompt-summary {
        display: flex;
        flex-direction: column;
        gap: 12px;
      }

      .prompt-snippet {
        border: 1px dashed #e2e8f0;
        border-radius: 12px;
        padding: 12px;
        font-size: 12px;
        color: #475569;
        background: #fff;
      }

      .prompt-section-list {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
      }

      .prompt-section-list span {
        font-size: 12px;
        padding: 4px 10px;
        border-radius: 999px;
        background: #e0e7ff;
        color: #3730a3;
      }

      .workspace-list {
        display: flex;
        flex-direction: column;
        gap: 8px;
        max-height: 280px;
        overflow-y: auto;
      }

      .workspace-item {
        border: 1px solid #e2e8f0;
        border-radius: 12px;
        padding: 12px;
        text-align: left;
        background: #fff;
        color: #0f172a;
      }

      .workspace-item span,
      .workspace-item div:nth-child(2) {
        color: #475569;
      }

      .workspace-item small,
      .workspace-item .workspace-meta {
        color: #94a3b8;
      }

      .workspace-item.active {
        border-color: #2563eb;
        background: #f8fbff;
      }

      .workspace-run-meta {
        display: flex;
        justify-content: space-between;
        font-size: 11px;
        color: #94a3b8;
        margin-top: 6px;
        gap: 8px;
      }

      .section-card {
        border: 1px solid #e2e8f0;
        border-radius: 16px;
        padding: 20px;
        background: #fff;
        display: flex;
        flex-direction: column;
        gap: 12px;
      }

      .section-card[data-status="running"] {
        border-color: #3b82f6;
        box-shadow: 0 0 0 1px rgba(59, 130, 246, 0.2);
      }

      .section-card[data-status="error"] {
        border-color: #f97316;
      }

      .section-grid {
        display: flex;
        flex-direction: column;
        gap: 16px;
      }

      .section-actions {
        display: flex;
        gap: 8px;
        align-items: center;
      }

      .section-output {
        border: 1px solid #e2e8f0;
        border-radius: 12px;
        padding: 16px;
        background: #fdfefe;
        min-height: 140px;
        font-size: 14px;
        line-height: 1.5;
      }

      .citations {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
        font-size: 12px;
        color: #475569;
      }

      .citations span {
        background: #f1f5f9;
        border-radius: 999px;
        padding: 2px 10px;
      }

      .section-error {
        background: #fef2f2;
        border: 1px solid #fecaca;
        color: #b91c1c;
        border-radius: 12px;
        padding: 12px;
        font-size: 13px;
      }

      @media (max-width: 1024px) {
        .reports-body {
          grid-template-columns: 1fr;
        }

        .documents-panel {
          height: auto;
        }
      }
    </style>

    <div class="reports-shell">
      <section class="patient-banner">
        <div>
          <div style="font-size: 12px; letter-spacing: 0.08em; text-transform: uppercase; color: #94a3b8; font-weight: 600;">
            Patient
          </div>
          <div style="font-size: 24px; font-weight: 600; color: #0f172a;">
            {patient_name(@patient)}
          </div>
          <div style="font-size: 14px; color: #475569;">
            MRN {patient_mrn(@patient)}
          </div>
        </div>
        <div class="patient-actions">
          <button class="manage-btn" phx-click="open_patient_modal">
            Manage Workspace
          </button>
          <button
            class="btn btn-primary"
            phx-click="run_full_report"
            disabled={MapSet.size(@running_sections) > 0}
          >
            <%= if MapSet.size(@running_sections) > 0 do %>
              Running…
            <% else %>
              Run All Sections
            <% end %>
          </button>
        </div>
      </section>

      <div class="reports-body">
        <aside class="documents-panel">
          <div style="display: flex; justify-content: space-between; align-items: center;">
            <div style="font-size: 13px; font-weight: 600; color: #0f172a;">Source Documents</div>
            <div style="font-size: 12px; color: #94a3b8;">{length(@documents)} files</div>
          </div>
          <form
            phx-change="noop"
            phx-submit="noop"
            phx-drop-target={@uploads.documents.ref}
            class="rounded-xl border border-dashed border-slate-300 p-4 flex flex-col gap-3 bg-slate-50"
          >
            <div class="text-sm text-slate-600">
              Drag & drop PDFs or click to select up to 5 files (25MB each). Uploads queue automatically once selected.
            </div>
            <div class="flex flex-col gap-2">
              <.live_file_input
                upload={@uploads.documents}
                class="cursor-pointer rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm w-full"
              />
              <button
                type="button"
                class="btn btn-primary btn-sm w-full"
                phx-click={JS.dispatch("click", to: "##{@uploads.documents.ref}")}
              >
                Select PDFs
              </button>
              <button
                type="button"
                class="btn btn-outline btn-sm w-full text-slate-700 border-slate-300"
                phx-click="seed_sample_documents"
              >
                Load Sample Documents
              </button>
            </div>
            <%= for entry <- @uploads.documents.entries do %>
              <div class="text-xs text-slate-500 flex items-center gap-2">
                <span>{entry.client_name}</span>
                <span>{entry.progress}%</span>
              </div>
            <% end %>
            <input type="hidden" name="noop" value="" />
          </form>
          <div class="document-list">
            <%= for doc <- @documents do %>
              <button
                class={[
                  "document-card",
                  @selected_document && @selected_document.id == doc.id && "active"
                ]}
                phx-click="select_document"
                phx-value-doc-id={doc.id}
              >
                <div class="flex items-center justify-between text-xs uppercase tracking-[0.15em] text-slate-400">
                  <span>Doc {doc.sequence}</span>
                  <%= if status_label = document_status(doc) do %>
                    <span class="text-[10px] rounded-full border border-slate-200 px-2 py-0.5 normal-case tracking-normal">
                      {String.capitalize(status_label)}
                    </span>
                  <% end %>
                </div>
                <div style="font-size: 13px; font-weight: 600; color: #0f172a;">
                  {doc.label}
                </div>
                <div style="font-size: 11px; color: #94a3b8;">{doc.kind}</div>
                <div style="font-size: 12px; color: #475569; margin-top: 4px;">
                  {doc.summary}
                </div>
                <%= if doc.ingestion_stage && doc.ingestion_stage != "completed" do %>
                  <div style="margin-top: 8px;">
                    <div style="height: 6px; background: #e2e8f0; border-radius: 999px; overflow: hidden;">
                      <div style={"height: 6px; background: #3b82f6; border-radius: 999px; width: #{doc.ingestion_progress || 0}%; transition: width 200ms ease;"}>
                      </div>
                    </div>
                    <div style="display: flex; justify-content: space-between; font-size: 10px; color: #94a3b8; margin-top: 4px;">
                      <span>{String.capitalize(doc.ingestion_stage)}</span>
                      <span>{doc.ingestion_progress || 0}%</span>
                    </div>
                    <%= if doc.ingestion_message do %>
                      <div style="font-size: 11px; color: #94a3b8; margin-top: 4px;">
                        {doc.ingestion_message}
                      </div>
                    <% end %>
                  </div>
                <% end %>
                <div style="font-size: 11px; color: #94a3b8; margin-top: 6px;">
                  {doc.provider} · {doc.date}
                </div>
              </button>
            <% end %>
          </div>
          <%= if @selected_document do %>
            <div style="border-top: 1px solid #e2e8f0; padding-top: 12px; display: flex; flex-direction: column; gap: 8px;">
              <div style="display: flex; justify-content: space-between; align-items: center;">
                <div>
                  <div style="font-size: 11px; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.08em;">
                    Document {@selected_document.sequence}
                  </div>
                  <div style="font-size: 16px; font-weight: 600; color: #0f172a;">
                    {@selected_document.label}
                  </div>
                  <div style="font-size: 12px; color: #94a3b8;">
                    {@selected_document.filename}
                  </div>
                </div>
                <div class="doc-detail-actions">
                  <button class="btn btn-outline btn-xs text-slate-600" phx-click="clear_document">
                    Collapse
                  </button>
                  <button
                    class="btn btn-error btn-xs"
                    phx-click="delete_document"
                    phx-value-doc-id={@selected_document.id}
                  >
                    Delete
                  </button>
                </div>
              </div>

              <div class="doc-detail-meta">
                <div>
                  <span>Uploaded</span>
                  <strong>{format_timestamp(@selected_document.uploaded_at)}</strong>
                </div>
                <div>
                  <span>File Size</span>
                  <strong>{@selected_document.byte_size_label}</strong>
                </div>
                <div>
                  <span>Status</span>
                  <strong>
                    {String.capitalize(document_status(@selected_document) || "pending")}
                  </strong>
                </div>
                <div>
                  <span>Type</span>
                  <strong>{@selected_document.content_type || "application/pdf"}</strong>
                </div>
                <%= if @selected_document.ingested_at do %>
                  <div>
                    <span>Processed</span>
                    <strong>{format_timestamp(@selected_document.ingested_at)}</strong>
                  </div>
                <% end %>
                <%= if @selected_document.ingestion_message do %>
                  <div>
                    <span>Stage</span>
                    <strong>{@selected_document.ingestion_message}</strong>
                  </div>
                <% end %>
              </div>

              <div style="font-size: 12px; color: #475569; white-space: pre-line; max-height: 200px; overflow-y: auto; border: 1px solid #e2e8f0; border-radius: 12px; padding: 12px; background: #fdfefe;">
                {@selected_document.cleaned_content ||
                  "This PDF is still being ingested. It will appear here when markdown is ready."}
              </div>
            </div>
          <% end %>
        </aside>

        <section class="section-grid">
          <%= for section_entry <- @sections do %>
            <article class="section-card" data-status={section_entry.status}>
              <header style="display: flex; justify-content: space-between; align-items: center;">
                <div>
                  <div style="font-size: 12px; text-transform: uppercase; color: #94a3b8; letter-spacing: 0.08em;">
                    Section
                  </div>
                  <div style="font-size: 18px; font-weight: 600; color: #0f172a;">
                    {section_entry.section.title}
                  </div>
                </div>
                <div class="section-actions">
                  <span style="font-size: 12px; color: #475569;">
                    {status_label(section_entry)}
                  </span>
                  <button
                    class={[
                      "btn btn-outline btn-sm border border-slate-300 text-slate-700 bg-white",
                      "hover:bg-slate-100 hover:text-slate-900 transition-colors"
                    ]}
                    phx-click="run_section"
                    phx-value-section-id={section_entry.section.id}
                    disabled={MapSet.member?(@running_sections, section_entry.section.id)}
                  >
                    <%= if MapSet.member?(@running_sections, section_entry.section.id) do %>
                      Running…
                    <% else %>
                      Run Section
                    <% end %>
                  </button>
                </div>
              </header>

              <div class="section-output">
                <%= if section_entry.last_run do %>
                  <div style="margin-bottom: 12px; font-size: 12px; color: #94a3b8;">
                    Updated {format_timestamp(section_entry.last_run.updated_at)}
                  </div>
                  <div class="markdown" style="font-size: 14px; color: #0f172a;">
                    {Phoenix.HTML.raw(section_entry.last_run.output_markdown || "Awaiting output")}
                  </div>
                <% else %>
                  <div style="font-size: 13px; color: #94a3b8;">
                    No output generated yet. Run this section to produce the initial draft.
                  </div>
                <% end %>
              </div>

              <%= if section_entry.last_run && section_entry.last_run.error do %>
                <div class="section-error">
                  <strong>Generation failed.</strong>
                  <div>
                    {Map.get(section_entry.last_run.error, "message") || "Unknown error"}
                  </div>
                </div>
              <% end %>

              <%= if section_entry.last_run && Enum.any?(section_entry.last_run.citations) do %>
                <div class="citations">
                  <%= for citation <- section_entry.last_run.citations do %>
                    <span>{citation.label}</span>
                  <% end %>
                </div>
              <% end %>
            </article>
          <% end %>
        </section>
      </div>
    </div>

    <%= if @patient_modal_open do %>
      <div class="modal-backdrop" phx-click="close_patient_modal">
        <div class="patient-modal" phx-click="noop">
          <div>
            <div style="font-size: 12px; text-transform: uppercase; color: #94a3b8; letter-spacing: 0.08em;">
              Patient
            </div>
            <div style="font-size: 20px; font-weight: 600; color: #0f172a;">
              {patient_name(@patient)}
            </div>
            <div style="font-size: 13px; color: #475569;">
              MRN {patient_mrn(@patient)} · DOB {patient_dob(@patient)}
            </div>
          </div>

          <div class="patient-modal-grid">
            <div class="modal-column">
              <section class="modal-panel">
                <h3>Demographics</h3>
                <p style="font-size: 12px; color: #64748b; margin-bottom: 4px;">
                  Keep the patient’s preferred identifiers current for every report.
                </p>
                <.form
                  for={@profile_form}
                  id="patient-profile-form"
                  phx-change="validate_patient_profile"
                  phx-submit="save_patient_profile"
                  class="flex flex-col gap-3"
                >
                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                    <.input
                      field={@profile_form[:given_name]}
                      label="Given name"
                      placeholder="Ada"
                    />
                    <.input
                      field={@profile_form[:family_name]}
                      label="Family name"
                      placeholder="Lovelace"
                    />
                    <.input field={@profile_form[:mrn]} label="MRN" placeholder="MRN-10293" />
                    <.input
                      field={@profile_form[:date_of_birth]}
                      type="date"
                      label="Date of birth"
                    />
                  </div>
                  <div class="flex items-center justify-between text-xs text-slate-500">
                    <span>Saved instantly for all workspaces</span>
                    <button type="submit" class="btn btn-primary btn-sm">Save changes</button>
                  </div>
                </.form>
              </section>

              <section class="modal-panel">
                <div style="display: flex; align-items: center; justify-content: space-between;">
                  <h3>Workspace context</h3>
                  <.link navigate={~p"/prompts"} class="btn btn-ghost btn-xs">
                    Open prompts
                  </.link>
                </div>

                <div>
                  <div style="font-size: 12px; text-transform: uppercase; color: #94a3b8; letter-spacing: 0.08em;">
                    Recent runs
                  </div>
                  <div class="recent-runs">
                    <%= if Enum.empty?(@recent_runs) do %>
                      <div class="prompt-snippet">
                        No report runs for this workspace yet. Trigger “Run All Sections” to see activity.
                      </div>
                    <% else %>
                      <%= for run <- @recent_runs do %>
                        <div class="recent-run">
                          <header>
                            <span>{String.capitalize(run.run_type || "full")} run</span>
                            <span class="status-pill" data-status={run.status || "pending"}>
                              {run_status_label(run)}
                            </span>
                          </header>
                          <p>
                            {run_timestamp_label(run)}
                          </p>
                        </div>
                      <% end %>
                    <% end %>
                  </div>
                </div>

                <div class="prompt-summary">
                  <div>
                    <div style="font-size: 12px; text-transform: uppercase; color: #94a3b8; letter-spacing: 0.08em;">
                      Ingestion prompt
                    </div>
                    <div class="prompt-snippet">
                      {prompt_excerpt(@template.ingestion_prompt_template)}
                    </div>
                  </div>
                  <div>
                    <div style="font-size: 12px; text-transform: uppercase; color: #94a3b8; letter-spacing: 0.08em;">
                      Report sections ({length(@template.sections)})
                    </div>
                    <div class="prompt-section-list">
                      <%= for section <- Enum.take(@template.sections, 4) do %>
                        <span>{section.title}</span>
                      <% end %>
                    </div>
                    <div
                      :if={length(@template.sections) > 4}
                      style="font-size: 11px; color: #94a3b8; margin-top: 4px;"
                    >
                      +{length(@template.sections) - 4} additional sections configured in prompts.
                    </div>
                  </div>
                </div>
              </section>
            </div>

            <div class="modal-column">
              <section class="modal-panel">
                <h3>Workspaces</h3>
                <p style="font-size: 12px; color: #64748b;">
                  Switch between document sets for the same patient. Each workspace keeps its own runs.
                </p>
                <div class="workspace-list">
                  <%= for set <- @record_sets do %>
                    <button
                      type="button"
                      class={["workspace-item", set.id == @record_set.id && "active"]}
                      phx-click="select_record_set"
                      phx-value-id={set.id}
                    >
                      <div style="font-size: 13px; font-weight: 600; color: #0f172a;">
                        {set.label}
                      </div>
                      <div style="font-size: 12px; color: #475569;">Status: {set.status}</div>
                      <div style="font-size: 11px; color: #94a3b8;">
                        Updated {format_timestamp(set.updated_at)}
                      </div>
                      <div class="workspace-run-meta">
                        <%= if run = Map.get(@record_set_latest_runs, set.id) do %>
                          <span>
                            {String.capitalize(run.run_type || "full")} · {run_status_label(run)}
                          </span>
                          <span>{format_timestamp(run_timestamp(run))}</span>
                        <% else %>
                          <span>No report runs yet.</span>
                        <% end %>
                      </div>
                    </button>
                  <% end %>
                  <%= if Enum.empty?(@record_sets) do %>
                    <div style="font-size: 13px; color: #94a3b8;">No workspaces yet.</div>
                  <% end %>
                </div>
              </section>
            </div>
          </div>

          <div class="patient-actions" style="justify-content: flex-end;">
            <button
              id="create-record-set"
              class="btn btn-primary btn-sm"
              phx-click="create_record_set"
            >
              New Workspace
            </button>
            <button class="btn btn-ghost btn-sm" phx-click="close_patient_modal">Close</button>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  defp profile_form(patient, attrs \\ %{}, action \\ nil) do
    patient
    |> Patients.profile_changeset(attrs)
    |> apply_form_action(action)
    |> to_form(as: :profile)
  end

  defp profile_form_from_changeset(changeset, action) do
    changeset
    |> apply_form_action(action)
    |> to_form(as: :profile)
  end

  defp apply_form_action(changeset, nil), do: changeset
  defp apply_form_action(changeset, action), do: Map.put(changeset, :action, action)

  defp run_status_label(%{status: status}) when is_binary(status), do: String.capitalize(status)
  defp run_status_label(_), do: "Pending"

  defp run_timestamp(%{finished_at: %DateTime{} = dt}), do: dt
  defp run_timestamp(%{started_at: %DateTime{} = dt}), do: dt
  defp run_timestamp(%{updated_at: %DateTime{} = dt}), do: dt
  defp run_timestamp(%{inserted_at: %DateTime{} = dt}), do: dt
  defp run_timestamp(_), do: nil

  defp run_timestamp_label(run) do
    case run_timestamp(run) do
      nil -> "Updated recently"
      dt -> "Updated #{format_timestamp(dt)}"
    end
  end

  defp prompt_excerpt(nil), do: "Ingestion prompt not yet configured."

  defp prompt_excerpt(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> truncate(260)
  end

  defp truncate(text, limit) do
    if String.length(text) <= limit do
      text
    else
      String.slice(text, 0, limit) <> "…"
    end
  end

  defp patient_name(%{current_profile: nil}), do: "Patient"

  defp patient_name(%{current_profile: profile}) do
    Enum.filter([profile.given_name, profile.family_name], & &1)
    |> Enum.join(" ")
  end

  defp patient_mrn(%{current_profile: nil}), do: "N/A"
  defp patient_mrn(%{current_profile: profile}), do: profile.mrn || "N/A"

  defp patient_dob(%{current_profile: nil}), do: "N/A"

  defp patient_dob(%{current_profile: profile}) do
    profile.date_of_birth || "N/A"
  end

  defp status_label(%{last_run: nil}), do: "Not generated"
  defp status_label(%{last_run: %{status: "completed"}}), do: "Ready"
  defp status_label(%{last_run: %{status: "queued"}}), do: "Queued"
  defp status_label(%{last_run: %{status: "running"}}), do: "Running"
  defp status_label(%{last_run: %{status: "error"}}), do: "Needs attention"
  defp status_label(%{last_run: %{status: status}}), do: status

  defp format_timestamp(nil), do: "recently"
  defp format_timestamp(dt), do: Calendar.strftime(dt, "%b %d · %H:%M UTC")

  defp humanize_errors(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} ->
      "#{humanize_field(field)} #{List.first(messages)}"
    end)
    |> Enum.join(", ")
  end

  defp humanize_field(field) when is_atom(field) do
    field
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
