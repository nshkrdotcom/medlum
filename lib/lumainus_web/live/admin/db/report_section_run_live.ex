defmodule LumainusWeb.Admin.Db.ReportSectionRunLive do
  use Backpex.LiveResource,
    layout: {LumainusWeb.AdminLayout, :app},
    adapter_config: [
      schema: Lumainus.Reports.ReportSectionRun,
      repo: Lumainus.Repo,
      update_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.report_section_run_changeset/3,
      create_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.report_section_run_changeset/3,
      item_query: &__MODULE__.item_query/3
    ],
    pubsub: [server: LumainusWeb.PubSub, topic: "report_section_runs"],
    init_order: %{by: :inserted_at, direction: :desc}

  import Ecto.Query

  def item_query(query, _live_action, _assigns) do
    from(q in query, preload: [:section_template, :report_run, :llm_invocation])
  end

  @impl Backpex.LiveResource
  def singular_name, do: "Report Section Run"

  @impl Backpex.LiveResource
  def plural_name, do: "Report Section Runs"

  @impl Backpex.LiveResource
  def filters(_assigns) do
    [
      report_run: %{
        module: LumainusWeb.Admin.Db.Filters.ReportRunFilter
      }
    ]
  end

  @impl Backpex.LiveResource
  def fields do
    [
      id: %{module: Backpex.Fields.Text, label: "ID", readonly: true, searchable: true},
      section_template: %{
        module: Backpex.Fields.BelongsTo,
        label: "Section",
        display_field: :title,
        live_resource: LumainusWeb.Admin.Db.ReportSectionTemplateLive
      },
      status: %{
        module: Backpex.Fields.Select,
        label: "Status",
        options: [
          {"Pending", "pending"},
          {"Queued", "queued"},
          {"Running", "running"},
          {"Completed", "completed"},
          {"Error", "error"},
          {"Timed Out", "timed_out"}
        ]
      },
      error: %{
        module: Backpex.Fields.Text,
        label: "Error",
        readonly: true,
        render: fn assigns ->
          error = assigns.value

          text =
            cond do
              is_nil(error) -> "-"
              is_map(error) -> Jason.encode!(error, pretty: true)
              true -> inspect(error)
            end

          assigns = Map.put(assigns, :text, text)
          ~H(<pre class="text-xs whitespace-pre-wrap max-w-xs overflow-auto"><%= @text %></pre>)
        end
      },
      confidence_score: %{
        module: Backpex.Fields.Number,
        label: "Confidence Score",
        readonly: true
      },
      report_run: %{
        module: Backpex.Fields.BelongsTo,
        label: "Report Run",
        display_field: :id,
        live_resource: LumainusWeb.Admin.Db.ReportRunLive
      },
      llm_invocation: %{
        module: Backpex.Fields.BelongsTo,
        label: "LLM Invocation",
        display_field: :id,
        live_resource: LumainusWeb.Admin.Db.LlmInvocationLive
      },
      output_markdown: %{
        module: Backpex.Fields.Textarea,
        label: "Output Markdown",
        readonly: true,
        except: [:index]
      },
      inserted_at: %{module: Backpex.Fields.DateTime, label: "Created At", readonly: true},
      updated_at: %{module: Backpex.Fields.DateTime, label: "Updated At", readonly: true}
    ]
  end
end
