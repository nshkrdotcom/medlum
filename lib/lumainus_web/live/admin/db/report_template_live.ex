defmodule LumainusWeb.Admin.Db.ReportTemplateLive do
  use Backpex.LiveResource,
    layout: {LumainusWeb.AdminLayout, :app},
    adapter_config: [
      schema: Lumainus.Reports.ReportTemplate,
      repo: Lumainus.Repo,
      update_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.report_template_changeset/3,
      create_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.report_template_changeset/3
    ],
    pubsub: [server: LumainusWeb.PubSub, topic: "report_templates"]

  @impl Backpex.LiveResource
  def singular_name, do: "Report Template"

  @impl Backpex.LiveResource
  def plural_name, do: "Report Templates"

  @impl Backpex.LiveResource
  def fields do
    [
      id: %{module: Backpex.Fields.Text, label: "ID", readonly: true},
      name: %{module: Backpex.Fields.Text, label: "Name", searchable: true},
      slug: %{module: Backpex.Fields.Text, label: "Slug", searchable: true},
      description: %{module: Backpex.Fields.Textarea, label: "Description"},
      status: %{
        module: Backpex.Fields.Select,
        label: "Status",
        options: [{"Active", "active"}, {"Draft", "draft"}, {"Archived", "archived"}]
      },
      version: %{module: Backpex.Fields.Number, label: "Version"},
      system_prompt: %{module: Backpex.Fields.Textarea, label: "System Prompt"},
      ingestion_prompt_template: %{
        module: Backpex.Fields.Textarea,
        label: "Ingestion Prompt Template"
      },
      tenant: %{
        module: Backpex.Fields.BelongsTo,
        label: "Tenant",
        display_field: :name,
        live_resource: LumainusWeb.Admin.Db.TenantLive
      },
      inserted_at: %{module: Backpex.Fields.DateTime, label: "Created At", readonly: true},
      updated_at: %{module: Backpex.Fields.DateTime, label: "Updated At", readonly: true}
    ]
  end
end
