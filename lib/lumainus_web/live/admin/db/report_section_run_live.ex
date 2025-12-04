defmodule LumainusWeb.Admin.Db.ReportSectionRunLive do
  use Backpex.LiveResource,
    layout: {LumainusWeb.AdminLayout, :app},
    adapter_config: [
      schema: Lumainus.Reports.ReportSectionRun,
      repo: Lumainus.Repo,
      update_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.report_section_run_changeset/3,
      create_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.report_section_run_changeset/3
    ],
    pubsub: [server: LumainusWeb.PubSub, topic: "report_section_runs"],
    init_order: %{by: :inserted_at, direction: :desc}

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
      output_markdown: %{
        module: Backpex.Fields.Textarea,
        label: "Output Markdown",
        readonly: true
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
      inserted_at: %{module: Backpex.Fields.DateTime, label: "Created At", readonly: true},
      updated_at: %{module: Backpex.Fields.DateTime, label: "Updated At", readonly: true}
    ]
  end
end
