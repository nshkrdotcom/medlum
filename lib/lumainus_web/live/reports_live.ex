defmodule LumainusWeb.ReportsLive do
  use LumainusWeb, :live_view

  alias Ecto.Changeset
  alias Lumainus.Documents
  alias Lumainus.Reports
  alias MapSet
  alias Path
  alias Phoenix.LiveView.JS

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

    if connected?(socket) do
      Documents.subscribe_to_record_set(socket.assigns.record_set.id)
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("select_document", %{"doc-id" => doc_id}, socket) do
    doc = Enum.find(socket.assigns.documents, &(&1.id == doc_id))
    {:noreply, assign(socket, selected_document: doc)}
  end

  @impl true
  def handle_event("clear_document", _params, socket) do
    {:noreply, assign(socket, selected_document: nil)}
  end

  @impl true
  def handle_event("run_section", %{"section-id" => section_id}, socket) do
    socket =
      assign(socket, :running_sections, MapSet.put(socket.assigns.running_sections, section_id))

    run_sections(socket, [section_id], fn updated_socket ->
      assign(
        updated_socket,
        :running_sections,
        MapSet.delete(updated_socket.assigns.running_sections, section_id)
      )
    end)
  end

  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("run_full_report", _params, socket) do
    section_ids = Enum.map(socket.assigns.sections, & &1.section.id)
    socket = assign(socket, :running_sections, MapSet.new(section_ids))

    run_sections(socket, section_ids, fn updated_socket ->
      assign(updated_socket, :running_sections, MapSet.new())
    end)
  end

  defp run_sections(socket, section_ids, after_fun) do
    scope = socket.assigns.current_scope

    case Reports.run_sections(
           scope,
           socket.assigns.patient,
           socket.assigns.record_set,
           socket.assigns.template,
           section_ids
         ) do
      {:ok, _run} ->
        updated =
          socket
          |> load_workspace()
          |> after_fun.()

        {:noreply, updated}

      {:error, reason} ->
        updated =
          socket
          |> put_flash(:error, "Report generation failed: #{inspect(reason)}")
          |> after_fun.()

        {:noreply, updated}
    end
  end

  defp load_workspace(socket) do
    scope = socket.assigns.current_scope
    workspace = Reports.workspace(scope)
    documents = format_documents(workspace.documents)
    sections = format_sections(workspace.sections)

    socket
    |> assign(:patient, workspace.patient)
    |> assign(:record_set, workspace.record_set)
    |> assign(:template, workspace.template)
    |> assign(:documents, documents)
    |> assign(:sections, sections)
    |> assign_new(:running_sections, fn -> MapSet.new() end)
    |> assign_new(:selected_document, fn -> nil end)
    |> assign_new(:job_subscriptions, fn -> MapSet.new() end)
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

  def handle_info(_message, socket), do: {:noreply, socket}

  defp handle_upload_progress(:documents, entry, socket) do
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

      entry_processed(socket, result)
    else
      {:noreply, socket}
    end
  end

  defp handle_upload_progress(_name, _entry, socket), do: {:noreply, socket}

  defp entry_processed(socket, {:ok, {:success, payload}}) do
    handle_consumed_entry(payload, socket)
  end

  defp entry_processed(socket, {:ok, {:error, reason}}) do
    {:noreply, put_flash(socket, :error, "Upload failed: #{inspect(reason)}")}
  end

  defp entry_processed(socket, {:postpone, _payload}), do: {:noreply, socket}

  defp entry_processed(socket, {:error, reason}) do
    {:noreply, put_flash(socket, :error, "Upload failed: #{inspect(reason)}")}
  end

  defp entry_processed(socket, _other), do: {:noreply, socket}

  defp handle_consumed_entry(%{binary: binary, meta: meta}, socket) do
    case persist_upload(meta, binary, socket) do
      {:ok, updated_socket} ->
        {:noreply,
         updated_socket
         |> put_flash(:info, "#{meta.filename} queued for ingestion.")
         |> load_workspace()}

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

      {:error, changeset} ->
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
    Enum.map(documents, fn doc ->
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
        ingestion_job_id: job_id
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
        <div style="display: flex; align-items: center; gap: 12px;">
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
                  <span>{doc.kind}</span>
                  <%= if status_label = document_status(doc) do %>
                    <span class="text-[10px] rounded-full border border-slate-200 px-2 py-0.5 normal-case tracking-normal">
                      {String.capitalize(status_label)}
                    </span>
                  <% end %>
                </div>
                <div style="font-size: 13px; font-weight: 600; color: #0f172a;">
                  {doc.label}
                </div>
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
            <div style="border-top: 1px solid #e2e8f0; padding-top: 12px;">
              <div style="display: flex; justify-content: space-between; align-items: center;">
                <div style="font-size: 12px; font-weight: 600; color: #0f172a;">
                  Document Detail
                </div>
                <button class="btn btn-ghost btn-xs" phx-click="clear_document">Close</button>
              </div>
              <div style="font-size: 12px; color: #475569; white-space: pre-line; margin-top: 8px; max-height: 200px; overflow-y: auto;">
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
    """
  end

  defp patient_name(%{current_profile: nil}), do: "Patient"

  defp patient_name(%{current_profile: profile}) do
    Enum.filter([profile.given_name, profile.family_name], & &1)
    |> Enum.join(" ")
  end

  defp patient_mrn(%{current_profile: nil}), do: "N/A"
  defp patient_mrn(%{current_profile: profile}), do: profile.mrn || "N/A"

  defp status_label(%{last_run: nil}), do: "Not generated"
  defp status_label(%{last_run: %{status: "completed"}}), do: "Ready"
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
