defmodule LumainusWeb.ReportsLive do
  use LumainusWeb, :live_view
  alias LumainusWeb.Medical.MockDocuments

  @impl true
  def mount(_params, _session, socket) do
    documents = MockDocuments.list_documents()
    report = MockDocuments.get_report()

    {:ok,
     socket
     |> assign(:documents, documents)
     |> assign(:report, report)
     |> assign(:selected_document, nil)
     |> assign(:document_view_mode, :summary)}
  end

  @impl true
  def handle_event("select_document", %{"doc-id" => doc_id}, socket) do
    document = Enum.find(socket.assigns.documents, &(&1.id == doc_id))

    {:noreply,
     socket
     |> assign(:selected_document, document)
     |> assign(:document_view_mode, :summary)}
  end

  @impl true
  def handle_event("change_view_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :document_view_mode, String.to_atom(mode))}
  end

  @impl true
  def handle_event("close_document", _params, socket) do
    {:noreply, assign(socket, :selected_document, nil)}
  end

  @impl true
  def handle_event("show_source", %{"doc-id" => doc_id}, socket) do
    document = Enum.find(socket.assigns.documents, &(&1.id == doc_id))

    {:noreply,
     socket
     |> assign(:selected_document, document)
     |> assign(:document_view_mode, :cleaned)
     |> push_event("scroll-to-document", %{doc_id: doc_id})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      .reports-shell {
        --nav-gap: 96px;
        min-height: 640px;
        height: calc(100vh - var(--nav-gap));
        background: #e2e8f0;
        padding: 1rem;
        display: flex;
        gap: 1rem;
      }

      .reports-sidebar {
        width: 320px;
        min-width: 280px;
        border-radius: 1.5rem;
        background: #ffffff;
        padding: 1rem;
        display: flex;
        flex-direction: column;
        box-shadow: inset 0 0 0 1px rgba(15, 23, 42, 0.05);
      }

      .reports-sidebar__list {
        margin-top: 0.75rem;
        overflow-y: auto;
        flex: 1;
        gap: 0.5rem;
        display: flex;
        flex-direction: column;
      }

      .reports-content {
        flex: 1;
        border-radius: 1.5rem;
        background: #ffffff;
        padding: 0.75rem 1rem;
        display: flex;
        flex-direction: column;
        box-shadow: inset 0 0 0 1px rgba(15, 23, 42, 0.05);
      }

      .reports-scroll {
        overflow-y: auto;
        flex: 1;
        padding-right: 0.5rem;
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
        gap: 0.75rem;
        align-content: flex-start;
      }

      .reports-section {
        min-height: 120px;
      }

      @media (max-width: 1024px) {
        .reports-shell {
          height: auto;
          min-height: 100vh;
          flex-direction: column;
          padding: 0.75rem;
        }

        .reports-sidebar,
        .reports-content {
          width: 100%;
          min-width: 0;
          border-radius: 1rem;
        }

        .reports-scroll {
          grid-template-columns: 1fr;
        }
      }
    </style>

    <div class="reports-shell">
      <aside class="reports-sidebar">
        <div>
          <p class="text-[0.7rem] uppercase tracking-[0.4em] text-slate-400 font-semibold">
            Documents
          </p>
          <p class="text-xs text-slate-500 mt-1">
            {length(@documents)} ingested sources
          </p>
        </div>

        <div class="reports-sidebar__list">
          <%= for doc <- @documents do %>
            <button
              id={"document-#{doc.id}"}
              phx-click="select_document"
              phx-value-doc-id={doc.id}
              class={[
                "text-left rounded-xl border border-slate-200 px-3 py-2 transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500",
                @selected_document && @selected_document.id == doc.id &&
                  "border-blue-500 bg-blue-50 shadow-sm"
              ]}
            >
              <span class={[
                "inline-flex items-center rounded-full px-2 py-0.5 text-[0.65rem] font-semibold mb-1",
                get_category_color(doc.type)
              ]}>
                {doc.type}
              </span>
              <div class="text-[0.7rem] text-slate-500">
                {Calendar.strftime(doc.date, "%b %d, %Y")} • {doc.provider}
              </div>
              <p class="mt-1 text-xs text-slate-700 line-clamp-2 leading-snug">
                {doc.summary}
              </p>
            </button>
          <% end %>
        </div>
      </aside>

      <section class="reports-content">
        <header class="border-b border-slate-200 pb-2 mb-2">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div>
              <p class="text-[0.7rem] uppercase tracking-[0.3em] text-blue-500 font-semibold">
                Clinical Summary
              </p>
              <h1 class="text-xl font-semibold text-slate-900 mt-1">
                {@report.patient_name}
              </h1>
            </div>
            <div class="text-right text-xs text-slate-500">
              <p>MRN · {@report.patient_mrn}</p>
              <p>Sources · {length(@documents)}</p>
            </div>
          </div>
        </header>

        <div class="reports-scroll">
          <.report_section title="Chief Complaint" id="chief-complaint" class="reports-section">
            <.render_with_sources content={@report.chief_complaint} />
          </.report_section>

          <.report_section title="History of Present Illness" id="hpi" class="reports-section">
            <div class="space-y-3 text-[0.85rem]">
              <div>
                <h4 class="font-semibold text-slate-700">Present Illness</h4>
                <.render_with_sources content={@report.hpi.present_illness} />
              </div>
              <div>
                <h4 class="font-semibold text-slate-700">Past Medical History</h4>
                <.render_with_sources content={@report.hpi.past_medical_history} />
              </div>
              <div>
                <h4 class="font-semibold text-slate-700">Past Surgical History</h4>
                <.render_with_sources content={@report.hpi.past_surgical_history} />
              </div>
              <div>
                <h4 class="font-semibold text-slate-700">Social History</h4>
                <.render_with_sources content={@report.hpi.social_history} />
              </div>
            </div>
          </.report_section>

          <.report_section title="Medications" id="medications" class="reports-section">
            <div class="space-y-2 text-[0.8rem]">
              <%= for med <- @report.medications do %>
                <div class="rounded-lg border border-slate-200 bg-white/80 px-3 py-2">
                  <div class="flex items-center justify-between text-slate-800">
                    <span class="font-semibold">{med.name}</span>
                    <span class="text-[0.65rem] uppercase tracking-widest text-slate-400">
                      {med.status}
                    </span>
                  </div>
                  <.render_with_sources content={med.indication} class="text-slate-600" />
                </div>
              <% end %>
            </div>
          </.report_section>

          <.report_section title="Past Physical Exam" id="exam" class="reports-section">
            <.render_with_sources content={@report.past_exam_findings} />
          </.report_section>

          <.report_section title="Review of Systems" id="ros" class="reports-section">
            <.render_with_sources content={@report.review_of_systems} />
          </.report_section>

          <.report_section title="Laboratory Results" id="labs" class="reports-section">
            <div class="space-y-2">
              <%= for lab <- @report.labs do %>
                <div class="rounded-lg border border-slate-200 bg-white/80 px-3 py-2">
                  <div class="flex items-center justify-between text-[0.8rem] text-slate-800">
                    <span>{lab.test}</span>
                    <.render_with_sources content={lab.date} class="text-slate-500" />
                  </div>
                  <.render_with_sources
                    content={lab.findings}
                    class="text-xs text-slate-600 whitespace-pre-line"
                  />
                </div>
              <% end %>
            </div>
          </.report_section>

          <.report_section title="Imaging Studies" id="imaging" class="reports-section">
            <div class="space-y-2">
              <%= for img <- @report.imaging do %>
                <div class="rounded-lg border border-slate-200 bg-white/80 px-3 py-2 text-xs">
                  <div class="flex items-center justify-between text-slate-800">
                    <span class="font-semibold">{img.study}</span>
                    <.render_with_sources content={img.date} class="text-slate-500" />
                  </div>
                  <div class="mt-1">
                    <span class="font-medium text-slate-700">Findings:</span>
                    <.render_with_sources
                      content={img.findings}
                      class="text-slate-600 whitespace-pre-line"
                    />
                  </div>
                  <div class="mt-1">
                    <span class="font-medium text-slate-700">Impression:</span>
                    <.render_with_sources content={img.impression} class="text-slate-600" />
                  </div>
                </div>
              <% end %>
            </div>
          </.report_section>

          <.report_section title="Pathology Results" id="pathology" class="reports-section">
            <%= if @report.pathology == [] do %>
              <p class="text-xs text-slate-500 italic">No pathology results available</p>
            <% else %>
              <div class="space-y-2">
                <%= for path <- @report.pathology do %>
                  <div class="rounded-lg border border-slate-200 bg-white/80 px-3 py-2 text-sm text-slate-700">
                    <.render_with_sources content={path} />
                  </div>
                <% end %>
              </div>
            <% end %>
          </.report_section>

          <.report_section title="Assessment" id="assessment" class="reports-section">
            <.render_with_sources
              content={@report.assessment}
              class="text-sm text-slate-700 whitespace-pre-line"
            />
          </.report_section>

          <.report_section title="Plan" id="plan" class="reports-section">
            <.render_with_sources
              content={@report.plan}
              class="text-sm text-slate-700 whitespace-pre-line"
            />
          </.report_section>
        </div>
      </section>
    </div>

    <%= if @selected_document do %>
      <div class="fixed inset-0 bg-black/60 flex items-center justify-center z-50 px-4">
        <div class="bg-white rounded-2xl shadow-2xl w-full max-w-5xl h-[85vh] flex flex-col">
          <div class="px-5 py-4 border-b border-slate-200 flex items-center justify-between">
            <div>
              <h3 class="text-lg font-semibold text-slate-900">{@selected_document.type}</h3>
              <p class="text-xs text-slate-500">
                {Calendar.strftime(@selected_document.date, "%b %d, %Y")} • {@selected_document.provider}
              </p>
            </div>
            <button
              phx-click="close_document"
              class="text-slate-400 hover:text-slate-600 transition-colors"
            >
              <svg
                class="w-5 h-5"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
          </div>
          <div class="flex border-b border-slate-200 px-5 space-x-2">
            <button
              phx-click="change_view_mode"
              phx-value-mode="summary"
              class={[
                "px-3 py-2 text-xs font-semibold tracking-widest uppercase",
                (@document_view_mode == :summary &&
                   "border-b-2 border-blue-500 text-blue-600") ||
                  "border-b-2 border-transparent text-slate-400 hover:text-slate-600"
              ]}
            >
              Summary
            </button>
            <button
              phx-click="change_view_mode"
              phx-value-mode="cleaned"
              class={[
                "px-3 py-2 text-xs font-semibold tracking-widest uppercase",
                (@document_view_mode == :cleaned &&
                   "border-b-2 border-blue-500 text-blue-600") ||
                  "border-b-2 border-transparent text-slate-400 hover:text-slate-600"
              ]}
            >
              Cleaned
            </button>
            <button
              phx-click="change_view_mode"
              phx-value-mode="raw"
              class={[
                "px-3 py-2 text-xs font-semibold tracking-widest uppercase",
                (@document_view_mode == :raw &&
                   "border-b-2 border-blue-500 text-blue-600") ||
                  "border-b-2 border-transparent text-slate-400 hover:text-slate-600"
              ]}
            >
              Raw
            </button>
          </div>
          <div class="flex-1 overflow-y-auto p-5 text-sm">
            <%= case @document_view_mode do %>
              <% :summary -> %>
                <div class="text-slate-700 leading-relaxed">
                  {@selected_document.summary}
                </div>
              <% :cleaned -> %>
                <div class="bg-slate-50 border border-slate-200 rounded-xl p-4 font-mono text-xs whitespace-pre-wrap">
                  {@selected_document.cleaned_content}
                </div>
              <% :raw -> %>
                <div class="bg-slate-900 text-emerald-200 rounded-xl p-4 font-mono text-[0.7rem] whitespace-pre-wrap">
                  {@selected_document.raw_content}
                </div>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  # Helper Components

  attr :title, :string, required: true
  attr :id, :string, required: true
  attr :class, :string, default: ""
  slot :inner_block, required: true

  defp report_section(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "rounded-xl border border-slate-200 bg-slate-50 px-3 py-3 text-[0.85rem] text-slate-700 shadow-sm",
        @class
      ]}
    >
      <h2 class="text-[0.75rem] font-semibold uppercase tracking-[0.25em] text-slate-500 mb-2">
        {@title}
      </h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :content, :string, required: true
  attr :class, :string, default: ""

  defp render_with_sources(assigns) do
    ~H"""
    <span class={@class}>
      <%= for part <- parse_content_with_sources(@content) do %>
        <%= case part do %>
          <% {:text, text} -> %>
            {text}
          <% {:source, doc_id} -> %>
            <button
              phx-click="show_source"
              phx-value-doc-id={doc_id}
              class="inline-flex items-center text-xs bg-blue-100 text-blue-700 px-2 py-0.5 rounded hover:bg-blue-200 transition-colors ml-1 font-medium"
              title={"View source document #{doc_id}"}
            >
              <svg
                class="w-3 h-3 mr-1"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
                />
              </svg>
              {doc_id}
            </button>
        <% end %>
      <% end %>
    </span>
    """
  end

  defp parse_content_with_sources(content) when is_binary(content) do
    parts = String.split(content, ~r/\|source:([^\|]+)/, include_captures: true)

    parts
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [text, "|source:" <> sources] ->
        source_list = String.split(sources, ",")
        [{:text, text}] ++ Enum.map(source_list, fn src -> {:source, String.trim(src)} end)

      [text] ->
        [{:text, text}]
    end)
  end

  defp get_category_color(type) do
    cond do
      String.contains?(type, "Doctor's Note") -> "bg-green-100 text-green-800"
      String.contains?(type, "Cardiology") -> "bg-red-100 text-red-800"
      String.contains?(type, "Lab") -> "bg-purple-100 text-purple-800"
      String.contains?(type, "Radiology") -> "bg-blue-100 text-blue-800"
      String.contains?(type, "Hospital") -> "bg-orange-100 text-orange-800"
      String.contains?(type, "Specialist") -> "bg-yellow-100 text-yellow-800"
      true -> "bg-gray-100 text-gray-800"
    end
  end
end
