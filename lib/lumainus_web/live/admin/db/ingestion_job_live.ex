defmodule LumainusWeb.Admin.Db.IngestionJobLive do
  use Backpex.LiveResource,
    layout: {LumainusWeb.AdminLayout, :app},
    adapter_config: [
      schema: Lumainus.Documents.IngestionJob,
      repo: Lumainus.Repo,
      update_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.ingestion_job_changeset/3,
      create_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.ingestion_job_changeset/3
    ],
    pubsub: [server: LumainusWeb.PubSub, topic: "ingestion_jobs"]

  import LumainusWeb.Admin.Db.BackpexHelpers

  @impl Backpex.LiveResource
  def singular_name, do: "Ingestion Job"

  @impl Backpex.LiveResource
  def plural_name, do: "Ingestion Jobs"

  @impl Backpex.LiveResource
  def fields do
    [
      id: %{module: Backpex.Fields.Text, label: "ID", readonly: true},
      job_type: %{module: Backpex.Fields.Text, label: "Job Type"},
      status: %{
        module: Backpex.Fields.Select,
        label: "Status",
        options: [
          {"Pending", "pending"},
          {"Processing", "processing"},
          {"Completed", "completed"},
          {"Failed", "failed"}
        ]
      },
      state: %{
        module: Backpex.Fields.Select,
        label: "State",
        options: [
          {"Pending", "pending"},
          {"Queued", "queued"},
          {"Running", "running"},
          {"Completed", "completed"},
          {"Failed", "failed"},
          {"Retrying", "retrying"}
        ]
      },
      stage: %{
        module: Backpex.Fields.Select,
        label: "Stage",
        options: [
          {"Queued", "queued"},
          {"Downloading", "downloading"},
          {"Docling", "docling"},
          {"Parsing", "parsing"},
          {"Completed", "completed"},
          {"Failed", "failed"}
        ]
      },
      backend: %{
        module: Backpex.Fields.Select,
        label: "Backend",
        options: [{"Local", "local"}, {"Fast", "fast"}, {"Cloud", "cloud"}]
      },
      progress: %{module: Backpex.Fields.Number, label: "Progress %"},
      attempt_number: %{module: Backpex.Fields.Number, label: "Attempt #", readonly: true},
      max_attempts: %{module: Backpex.Fields.Number, label: "Max Attempts"},
      last_message: %{module: Backpex.Fields.Text, label: "Last Message", readonly: true},
      last_error: %{module: Backpex.Fields.Textarea, label: "Last Error", readonly: true},
      started_at: %{
        module: Backpex.Fields.DateTime,
        label: "Started At",
        readonly: true,
        render: datetime_render()
      },
      finished_at: %{
        module: Backpex.Fields.DateTime,
        label: "Finished At",
        readonly: true,
        render: datetime_render()
      },
      timeout_at: %{
        module: Backpex.Fields.DateTime,
        label: "Timeout At",
        render: datetime_render()
      },
      tenant: %{
        module: Backpex.Fields.BelongsTo,
        label: "Tenant",
        display_field: :name,
        live_resource: LumainusWeb.Admin.Db.TenantLive
      },
      upload: %{
        module: Backpex.Fields.BelongsTo,
        label: "Upload",
        display_field: :filename,
        live_resource: LumainusWeb.Admin.Db.DocumentUploadLive
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
