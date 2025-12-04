defmodule LumainusWeb.Admin.Db.DocumentUploadLive do
  use Backpex.LiveResource,
    layout: {LumainusWeb.AdminLayout, :app},
    adapter_config: [
      schema: Lumainus.Documents.DocumentUpload,
      repo: Lumainus.Repo,
      update_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.document_upload_changeset/3,
      create_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.document_upload_changeset/3
    ],
    pubsub: [server: LumainusWeb.PubSub, topic: "document_uploads"]

  @impl Backpex.LiveResource
  def singular_name, do: "Document Upload"

  @impl Backpex.LiveResource
  def plural_name, do: "Document Uploads"

  @impl Backpex.LiveResource
  def fields do
    [
      id: %{module: Backpex.Fields.Text, label: "ID", readonly: true},
      filename: %{module: Backpex.Fields.Text, label: "Filename", searchable: true},
      document_kind: %{module: Backpex.Fields.Text, label: "Document Kind"},
      content_type: %{module: Backpex.Fields.Text, label: "Content Type"},
      byte_size: %{module: Backpex.Fields.Number, label: "File Size (bytes)", readonly: true},
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
      storage_backend: %{
        module: Backpex.Fields.Select,
        label: "Storage Backend",
        options: [{"Postgres", "postgres"}, {"S3", "s3"}, {"Local", "local"}]
      },
      sha256: %{module: Backpex.Fields.Text, label: "SHA256", readonly: true},
      ingested_at: %{module: Backpex.Fields.DateTime, label: "Ingested At", readonly: true},
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
      inserted_at: %{module: Backpex.Fields.DateTime, label: "Created At", readonly: true},
      updated_at: %{module: Backpex.Fields.DateTime, label: "Updated At", readonly: true}
    ]
  end
end
