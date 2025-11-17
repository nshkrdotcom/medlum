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
      /* Professional medical form layout - tight, clean, no decorative elements */
      .medical-chart {
        height: calc(100vh - 96px);
        background: #fafafa;
        display: flex;
        gap: 1px;
      }

      .chart-sidebar {
        width: 280px;
        background: #fff;
        border-right: 1px solid #d0d0d0;
        display: flex;
        flex-direction: column;
      }

      .chart-sidebar-header {
        padding: 8px 12px;
        border-bottom: 1px solid #d0d0d0;
        background: #f5f5f5;
      }

      .chart-sidebar-list {
        flex: 1;
        overflow-y: auto;
      }

      .doc-item {
        padding: 8px 12px;
        border-bottom: 1px solid #e8e8e8;
        background: #fff;
        text-align: left;
        width: 100%;
        transition: background 0.1s;
      }

      .doc-item:hover {
        background: #f9f9f9;
      }

      .doc-item.selected {
        background: #f0f0f0;
        border-left: 3px solid #000;
        padding-left: 9px;
      }

      .chart-main {
        flex: 1;
        background: #fff;
        display: flex;
        flex-direction: column;
      }

      .chart-header {
        padding: 12px 16px;
        border-bottom: 2px solid #000;
        background: #fff;
      }

      .chart-body {
        flex: 1;
        overflow-y: auto;
        padding: 0;
      }

      .chart-section {
        border-bottom: 1px solid #d0d0d0;
        padding: 10px 16px;
      }

      .chart-section:last-child {
        border-bottom: none;
      }

      .section-title {
        font-size: 11px;
        font-weight: 600;
        text-transform: uppercase;
        letter-spacing: 0.5px;
        color: #000;
        margin: 0 0 6px 0;
        padding-bottom: 4px;
        border-bottom: 1px solid #e0e0e0;
      }

      .section-content {
        font-size: 13px;
        line-height: 1.5;
        color: #1a1a1a;
      }

      .subsection {
        margin: 6px 0;
      }

      .subsection-title {
        font-size: 12px;
        font-weight: 600;
        color: #000;
        margin-bottom: 2px;
      }

      .data-row {
        padding: 6px 8px;
        margin: 4px 0;
        background: #fafafa;
        border-left: 2px solid #e0e0e0;
        font-size: 12px;
      }

      .data-label {
        font-weight: 600;
        color: #000;
        margin-right: 4px;
      }

      /* Mobile responsive */
      @media (max-width: 1024px) {
        .medical-chart {
          height: auto;
          min-height: 100vh;
          flex-direction: column;
        }

        .chart-sidebar {
          width: 100%;
          border-right: none;
          border-bottom: 1px solid #d0d0d0;
          max-height: 300px;
        }

        .chart-section {
          padding: 12px 16px;
        }

        .section-content {
          font-size: 14px;
        }
      }
    </style>

    <div class="medical-chart">
      <!-- Document List Sidebar -->
      <aside class="chart-sidebar">
        <div class="chart-sidebar-header">
          <div style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; color: #666;">
            Source Documents
          </div>
          <div style="font-size: 11px; color: #999; margin-top: 2px;">
            {length(@documents)} records
          </div>
        </div>

        <div class="chart-sidebar-list">
          <%= for doc <- @documents do %>
            <button
              id={"document-#{doc.id}"}
              phx-click="select_document"
              phx-value-doc-id={doc.id}
              class={[
                "doc-item",
                @selected_document && @selected_document.id == doc.id && "selected"
              ]}
            >
              <div style="font-size: 10px; font-weight: 600; color: #666; margin-bottom: 3px;">
                {doc.type}
              </div>
              <div style="font-size: 11px; color: #999; margin-bottom: 3px;">
                {Calendar.strftime(doc.date, "%m/%d/%Y")} · {doc.provider}
              </div>
              <div style="font-size: 11px; color: #333; line-height: 1.3;">
                {String.slice(doc.summary, 0, 80)}{if String.length(doc.summary) > 80,
                  do: "...",
                  else: ""}
              </div>
            </button>
          <% end %>
        </div>
      </aside>
      
    <!-- Main Report Area -->
      <main class="chart-main">
        <header class="chart-header">
          <div style="display: flex; justify-content: space-between; align-items: baseline;">
            <div>
              <div style="font-size: 10px; font-weight: 600; color: #666; letter-spacing: 0.5px; text-transform: uppercase;">
                Clinical Summary Report
              </div>
              <h1 style="font-size: 18px; font-weight: 600; color: #000; margin: 4px 0 0 0;">
                {@report.patient_name}
              </h1>
            </div>
            <div style="text-align: right; font-size: 11px; color: #666;">
              <div>MRN: {@report.patient_mrn}</div>
              <div style="margin-top: 2px;">{length(@documents)} source documents</div>
            </div>
          </div>
        </header>

        <div class="chart-body">
          <!-- Chief Complaint -->
          <section class="chart-section">
            <h2 class="section-title">Chief Complaint</h2>
            <div class="section-content">
              <.render_with_sources content={@report.chief_complaint} />
            </div>
          </section>
          
    <!-- HPI -->
          <section class="chart-section">
            <h2 class="section-title">History of Present Illness</h2>
            <div class="section-content">
              <div class="subsection">
                <div class="subsection-title">Present Illness</div>
                <.render_with_sources content={@report.hpi.present_illness} />
              </div>
              <div class="subsection">
                <div class="subsection-title">Past Medical History</div>
                <.render_with_sources content={@report.hpi.past_medical_history} />
              </div>
              <div class="subsection">
                <div class="subsection-title">Past Surgical History</div>
                <.render_with_sources content={@report.hpi.past_surgical_history} />
              </div>
              <div class="subsection">
                <div class="subsection-title">Social History</div>
                <.render_with_sources content={@report.hpi.social_history} />
              </div>
            </div>
          </section>
          
    <!-- Medications -->
          <section class="chart-section">
            <h2 class="section-title">Medications</h2>
            <div class="section-content">
              <%= for med <- @report.medications do %>
                <div class="data-row">
                  <span class="data-label">{med.name}</span>
                  <span style="font-size: 10px; color: #999; text-transform: uppercase; margin-left: 8px;">
                    {med.status}
                  </span>
                  <div style="margin-top: 2px; font-size: 11px; color: #666;">
                    <.render_with_sources content={med.indication} />
                  </div>
                </div>
              <% end %>
            </div>
          </section>
          
    <!-- Past Physical Exam -->
          <section class="chart-section">
            <h2 class="section-title">Past Physical Exam Findings</h2>
            <div class="section-content">
              <.render_with_sources content={@report.past_exam_findings} />
            </div>
          </section>
          
    <!-- Review of Systems -->
          <section class="chart-section">
            <h2 class="section-title">Review of Systems</h2>
            <div class="section-content">
              <.render_with_sources content={@report.review_of_systems} />
            </div>
          </section>
          
    <!-- Labs -->
          <section class="chart-section">
            <h2 class="section-title">Laboratory Results</h2>
            <div class="section-content">
              <%= for lab <- @report.labs do %>
                <div class="data-row">
                  <div style="display: flex; justify-content: space-between; margin-bottom: 2px;">
                    <span class="data-label">{lab.test}</span>
                    <span style="font-size: 11px; color: #999;">
                      <.render_with_sources content={lab.date} />
                    </span>
                  </div>
                  <div style="font-size: 11px; color: #666; white-space: pre-line;">
                    <.render_with_sources content={lab.findings} />
                  </div>
                </div>
              <% end %>
            </div>
          </section>
          
    <!-- Imaging -->
          <section class="chart-section">
            <h2 class="section-title">Imaging Studies</h2>
            <div class="section-content">
              <%= for img <- @report.imaging do %>
                <div class="data-row" style="margin-bottom: 8px;">
                  <div style="display: flex; justify-content: space-between; margin-bottom: 4px;">
                    <span class="data-label">{img.study}</span>
                    <span style="font-size: 11px; color: #999;">
                      <.render_with_sources content={img.date} />
                    </span>
                  </div>
                  <div style="font-size: 11px; color: #666; margin-bottom: 3px;">
                    <span class="data-label" style="font-size: 11px;">Findings:</span>
                    <.render_with_sources content={img.findings} />
                  </div>
                  <div style="font-size: 11px; color: #666;">
                    <span class="data-label" style="font-size: 11px;">Impression:</span>
                    <.render_with_sources content={img.impression} />
                  </div>
                </div>
              <% end %>
            </div>
          </section>
          
    <!-- Pathology -->
          <section class="chart-section">
            <h2 class="section-title">Pathology Results</h2>
            <div class="section-content">
              <%= if @report.pathology == [] do %>
                <div style="font-size: 11px; color: #999; font-style: italic;">
                  No pathology results available
                </div>
              <% else %>
                <%= for path <- @report.pathology do %>
                  <div class="data-row">
                    <.render_with_sources content={path} />
                  </div>
                <% end %>
              <% end %>
            </div>
          </section>
          
    <!-- Assessment -->
          <section class="chart-section">
            <h2 class="section-title">Assessment</h2>
            <div class="section-content" style="white-space: pre-line;">
              <.render_with_sources content={@report.assessment} />
            </div>
          </section>
          
    <!-- Plan -->
          <section class="chart-section">
            <h2 class="section-title">Plan</h2>
            <div class="section-content" style="white-space: pre-line;">
              <.render_with_sources content={@report.plan} />
            </div>
          </section>
        </div>
      </main>
    </div>

    <%= if @selected_document do %>
      <div
        class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50"
        style="padding: 20px;"
      >
        <div
          class="bg-white w-full h-full flex flex-col"
          style="max-width: 1200px; max-height: 90vh; border: 2px solid #000;"
        >
          <!-- Modal Header -->
          <div style="padding: 12px 16px; border-bottom: 2px solid #000; display: flex; justify-content: space-between; align-items: center; background: #f5f5f5;">
            <div>
              <h3 style="font-size: 14px; font-weight: 600; color: #000; margin: 0;">
                {@selected_document.type}
              </h3>
              <p style="font-size: 11px; color: #666; margin: 2px 0 0 0;">
                {Calendar.strftime(@selected_document.date, "%m/%d/%Y")} · {@selected_document.provider}
              </p>
            </div>
            <button
              phx-click="close_document"
              style="background: none; border: none; cursor: pointer; padding: 4px; color: #666;"
            >
              <svg
                style="width: 20px; height: 20px;"
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
          <div style="display: flex; border-bottom: 1px solid #d0d0d0; background: #fff;">
            <button
              phx-click="change_view_mode"
              phx-value-mode="summary"
              style={[
                "padding: 8px 16px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; border: none; background: none; cursor: pointer;",
                if(@document_view_mode == :summary,
                  do: "border-bottom: 2px solid #000; color: #000;",
                  else: "color: #999;"
                )
              ]}
            >
              Summary
            </button>
            <button
              phx-click="change_view_mode"
              phx-value-mode="cleaned"
              style={[
                "padding: 8px 16px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; border: none; background: none; cursor: pointer;",
                if(@document_view_mode == :cleaned,
                  do: "border-bottom: 2px solid #000; color: #000;",
                  else: "color: #999;"
                )
              ]}
            >
              Cleaned
            </button>
            <button
              phx-click="change_view_mode"
              phx-value-mode="raw"
              style={[
                "padding: 8px 16px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; border: none; background: none; cursor: pointer;",
                if(@document_view_mode == :raw,
                  do: "border-bottom: 2px solid #000; color: #000;",
                  else: "color: #999;"
                )
              ]}
            >
              Raw
            </button>
          </div>
          
    <!-- Modal Content -->
          <div style="flex: 1; overflow-y: auto; padding: 16px; font-size: 13px; line-height: 1.6;">
            <%= case @document_view_mode do %>
              <% :summary -> %>
                <div style="color: #1a1a1a;">
                  {@selected_document.summary}
                </div>
              <% :cleaned -> %>
                <div style="background: #f5f5f5; padding: 12px; border: 1px solid #d0d0d0; font-family: 'Courier New', monospace; font-size: 11px; white-space: pre-wrap; color: #000;">
                  {@selected_document.cleaned_content}
                </div>
              <% :raw -> %>
                <div style="background: #1a1a1a; color: #00ff00; padding: 12px; border: 1px solid #000; font-family: 'Courier New', monospace; font-size: 11px; white-space: pre-wrap;">
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

  attr :content, :string, required: true

  defp render_with_sources(assigns) do
    ~H"""
    <span>
      <%= for part <- parse_content_with_sources(@content) do %>
        <%= case part do %>
          <% {:text, text} -> %>
            {text}
          <% {:source, doc_id} -> %>
            <button
              phx-click="show_source"
              phx-value-doc-id={doc_id}
              style="display: inline-flex; align-items: center; font-size: 10px; background: #e8e8e8; color: #000; padding: 2px 6px; border: 1px solid #d0d0d0; margin-left: 4px; font-weight: 600; cursor: pointer; vertical-align: baseline;"
              title={"View source document #{doc_id}"}
            >
              <svg
                style="width: 10px; height: 10px; margin-right: 3px;"
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

  # No longer needed - keeping for backwards compatibility
  defp get_category_color(_type) do
    ""
  end
end
