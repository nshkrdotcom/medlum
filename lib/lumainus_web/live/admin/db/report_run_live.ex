defmodule LumainusWeb.Admin.Db.ReportRunLive do
  use Backpex.LiveResource,
    layout: {LumainusWeb.AdminLayout, :app},
    adapter_config: [
      schema: Lumainus.Reports.ReportRun,
      repo: Lumainus.Repo,
      update_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.report_run_changeset/3,
      create_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.report_run_changeset/3,
      item_query: &__MODULE__.item_query/3
    ],
    pubsub: [server: LumainusWeb.PubSub, topic: "report_runs"],
    init_order: %{by: :inserted_at, direction: :desc}

  import Ecto.Query
  import LumainusWeb.Admin.Db.BackpexHelpers

  def item_query(query, _live_action, _assigns) do
    from(q in query, preload: [:tenant, :patient])
  end

  @impl Backpex.LiveResource
  def singular_name, do: "Report Run"

  @impl Backpex.LiveResource
  def plural_name, do: "Report Runs"

  @impl Backpex.LiveResource
  def fields do
    [
      id: %{module: Backpex.Fields.Text, label: "ID", readonly: true, searchable: true},
      run_type: %{
        module: Backpex.Fields.Select,
        label: "Run Type",
        options: [{"Full", "full"}, {"Partial", "partial"}, {"Single", "single"}]
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
      started_at: %{
        module: Backpex.Fields.DateTime,
        label: "Started At",
        render: datetime_render()
      },
      finished_at: %{
        module: Backpex.Fields.DateTime,
        label: "Finished At",
        render: datetime_render()
      },
      timeout_at: %{
        module: Backpex.Fields.DateTime,
        label: "Timeout At",
        render: datetime_render()
      },
      last_activity_at: %{
        module: Backpex.Fields.DateTime,
        label: "Last Activity At",
        render: datetime_render()
      },
      tenant: %{
        module: Backpex.Fields.BelongsTo,
        label: "Tenant",
        display_field: :name,
        live_resource: LumainusWeb.Admin.Db.TenantLive
      },
      patient: %{
        module: Backpex.Fields.BelongsTo,
        label: "Patient",
        display_field: :patient_key,
        live_resource: LumainusWeb.Admin.Db.PatientLive
      },
      inserted_at: %{
        module: Backpex.Fields.DateTime,
        label: "Created At",
        readonly: true,
        render: datetime_render()
      },
      updated_at: %{
        module: Backpex.Fields.DateTime,
        label: "Updated At",
        readonly: true,
        render: datetime_render()
      }
    ]
  end
end
