defmodule LumainusWebWeb.ReportsLive do
  use LumainusWebWeb, :live_view
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
    <div class="flex h-screen bg-gray-50">
      <!-- Left Sidebar - Document List -->
      <div class="w-1/4 bg-white shadow-lg overflow-y-auto border-r border-gray-200">
        <div class="p-6 border-b border-gray-200 bg-blue-50">
          <h2 class="text-xl font-bold text-gray-800">Medical Documents</h2>
          <p class="text-sm text-gray-600 mt-1">{length(@documents)} documents ingested</p>
        </div>

        <div class="divide-y divide-gray-200">
          <%= for doc <- @documents do %>
            <div
              id={"document-#{doc.id}"}
              class={[
                "p-4 cursor-pointer hover:bg-blue-50 transition-colors",
                @selected_document && @selected_document.id == doc.id &&
                  "bg-blue-100 border-l-4 border-blue-600"
              ]}
              phx-click="select_document"
              phx-value-doc-id={doc.id}
            >
              <div class="flex items-start justify-between">
                <div class="flex-1">
                  <span class={[
                    "inline-block px-2 py-1 text-xs font-semibold rounded-full mb-2",
                    get_category_color(doc.type)
                  ]}>
                    {doc.type}
                  </span>
                  <div class="text-sm text-gray-500 mb-1">
                    {Calendar.strftime(doc.date, "%B %d, %Y")} • {doc.provider}
                  </div>
                  <p class="text-sm text-gray-700 line-clamp-3">
                    {doc.summary}
                  </p>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
      
    <!-- Main Content Area - Report -->
      <div class="flex-1 overflow-y-auto">
        <div class="max-w-5xl mx-auto p-8">
          <!-- Header -->
          <div class="bg-white shadow-sm rounded-lg p-6 mb-6 border border-gray-200">
            <h1 class="text-3xl font-bold text-gray-900">Clinical Summary Report</h1>
            <div class="mt-2 text-gray-600">
              <p class="text-lg">
                <span class="font-semibold">Patient:</span>
                {@report.patient_name}
              </p>
              <p>
                <span class="font-semibold">MRN:</span>
                {@report.patient_mrn}
              </p>
              <p class="text-sm text-gray-500 mt-2">
                Generated from {length(@documents)} documents
              </p>
            </div>
          </div>
          <!-- Chief Complaint -->
          <.report_section title="Chief Complaint" id="chief-complaint">
            <.render_with_sources content={@report.chief_complaint} />
          </.report_section>
          <!-- HPI -->
          <.report_section title="History of Present Illness" id="hpi">
            <div class="space-y-4">
              <div>
                <h4 class="font-semibold text-gray-700 mb-2">Present Illness</h4>
                <.render_with_sources content={@report.hpi.present_illness} />
              </div>
              <div>
                <h4 class="font-semibold text-gray-700 mb-2">Past Medical History</h4>
                <.render_with_sources content={@report.hpi.past_medical_history} />
              </div>
              <div>
                <h4 class="font-semibold text-gray-700 mb-2">Past Surgical History</h4>
                <.render_with_sources content={@report.hpi.past_surgical_history} />
              </div>
              <div>
                <h4 class="font-semibold text-gray-700 mb-2">Social History</h4>
                <.render_with_sources content={@report.hpi.social_history} />
              </div>
            </div>
          </.report_section>
          <!-- Medications -->
          <.report_section title="Medications" id="medications">
            <div class="space-y-3">
              <%= for med <- @report.medications do %>
                <div class="bg-gray-50 p-3 rounded border border-gray-200">
                  <div class="font-semibold text-gray-800">{med.name}</div>
                  <div class="text-sm text-gray-600">
                    <.render_with_sources content={med.indication} />
                  </div>
                  <div class="text-xs text-gray-500 mt-1">Status: {med.status}</div>
                </div>
              <% end %>
            </div>
          </.report_section>
          <!-- Past Physical Exam Findings -->
          <.report_section title="Past Physical Exam Findings" id="exam">
            <.render_with_sources content={@report.past_exam_findings} />
          </.report_section>
          <!-- Review of Systems -->
          <.report_section title="Review of Systems" id="ros">
            <.render_with_sources content={@report.review_of_systems} />
          </.report_section>
          <!-- Labs -->
          <.report_section title="Laboratory Results" id="labs">
            <div class="space-y-4">
              <%= for lab <- @report.labs do %>
                <div class="bg-gray-50 p-4 rounded border border-gray-200">
                  <div class="font-semibold text-gray-800 mb-1">
                    {lab.test} - <.render_with_sources content={lab.date} />
                  </div>
                  <.render_with_sources content={lab.findings} class="text-sm whitespace-pre-line" />
                </div>
              <% end %>
            </div>
          </.report_section>
          <!-- Imaging -->
          <.report_section title="Imaging Studies" id="imaging">
            <div class="space-y-4">
              <%= for img <- @report.imaging do %>
                <div class="bg-gray-50 p-4 rounded border border-gray-200">
                  <div class="font-semibold text-gray-800 mb-1">
                    {img.study} - <.render_with_sources content={img.date} />
                  </div>
                  <div class="text-sm mb-2">
                    <span class="font-medium text-gray-700">Findings:</span>
                    <.render_with_sources content={img.findings} class="whitespace-pre-line" />
                  </div>
                  <div class="text-sm">
                    <span class="font-medium text-gray-700">Impression:</span>
                    <.render_with_sources content={img.impression} />
                  </div>
                </div>
              <% end %>
            </div>
          </.report_section>
          <!-- Pathology -->
          <.report_section title="Pathology Results" id="pathology">
            <%= if @report.pathology == [] do %>
              <p class="text-gray-500 italic">No pathology results available</p>
            <% else %>
              <div class="space-y-4">
                <%= for path <- @report.pathology do %>
                  <div class="bg-gray-50 p-4 rounded border border-gray-200">
                    <.render_with_sources content={path} />
                  </div>
                <% end %>
              </div>
            <% end %>
          </.report_section>
          <!-- Assessment -->
          <.report_section title="Assessment" id="assessment">
            <.render_with_sources content={@report.assessment} class="whitespace-pre-line" />
          </.report_section>
          <!-- Plan -->
          <.report_section title="Plan" id="plan">
            <.render_with_sources content={@report.plan} class="whitespace-pre-line" />
          </.report_section>
        </div>
      </div>
      
    <!-- Right Overlay - Selected Document Detail -->
      <%= if @selected_document do %>
        <div class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
          <div class="bg-white rounded-lg shadow-2xl w-3/4 h-3/4 flex flex-col">
            <!-- Modal Header -->
            <div class="p-6 border-b border-gray-200 flex items-center justify-between">
              <div>
                <h3 class="text-xl font-bold text-gray-900">{@selected_document.type}</h3>
                <p class="text-sm text-gray-600">
                  {Calendar.strftime(@selected_document.date, "%B %d, %Y")} • {@selected_document.provider}
                </p>
              </div>
              <button
                phx-click="close_document"
                class="text-gray-400 hover:text-gray-600 transition-colors"
              >
                <svg
                  class="w-6 h-6"
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
            <!-- View Mode Tabs -->
            <div class="flex border-b border-gray-200 px-6">
              <button
                phx-click="change_view_mode"
                phx-value-mode="summary"
                class={[
                  "px-4 py-2 font-medium text-sm border-b-2 transition-colors",
                  (@document_view_mode == :summary &&
                     "border-blue-600 text-blue-600") ||
                    "border-transparent text-gray-500 hover:text-gray-700"
                ]}
              >
                Summary
              </button>
              <button
                phx-click="change_view_mode"
                phx-value-mode="cleaned"
                class={[
                  "px-4 py-2 font-medium text-sm border-b-2 transition-colors",
                  (@document_view_mode == :cleaned &&
                     "border-blue-600 text-blue-600") ||
                    "border-transparent text-gray-500 hover:text-gray-700"
                ]}
              >
                Cleaned
              </button>
              <button
                phx-click="change_view_mode"
                phx-value-mode="raw"
                class={[
                  "px-4 py-2 font-medium text-sm border-b-2 transition-colors",
                  (@document_view_mode == :raw &&
                     "border-blue-600 text-blue-600") ||
                    "border-transparent text-gray-500 hover:text-gray-700"
                ]}
              >
                Raw
              </button>
            </div>
            <!-- Modal Content -->
            <div class="flex-1 overflow-y-auto p-6">
              <%= case @document_view_mode do %>
                <% :summary -> %>
                  <div class="prose max-w-none">
                    <p class="text-gray-700">{@selected_document.summary}</p>
                  </div>
                <% :cleaned -> %>
                  <div class="bg-gray-50 p-4 rounded border border-gray-200 font-mono text-sm whitespace-pre-wrap">
                    {@selected_document.cleaned_content}
                  </div>
                <% :raw -> %>
                  <div class="bg-gray-900 text-green-400 p-4 rounded font-mono text-xs whitespace-pre-wrap">
                    {@selected_document.raw_content}
                  </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Helper Components

  attr :title, :string, required: true
  attr :id, :string, required: true
  slot :inner_block, required: true

  defp report_section(assigns) do
    ~H"""
    <div id={@id} class="bg-white shadow-sm rounded-lg p-6 mb-6 border border-gray-200">
      <h2 class="text-2xl font-bold text-gray-900 mb-4 border-b-2 border-blue-600 pb-2">
        {@title}
      </h2>
      <div class="text-gray-700">
        {render_slot(@inner_block)}
      </div>
    </div>
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
