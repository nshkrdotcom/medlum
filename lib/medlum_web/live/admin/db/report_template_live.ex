defmodule MedlumWeb.Admin.Db.ReportTemplateLive do
  use Backpex.LiveResource,
    layout: {MedlumWeb.AdminLayout, :app},
    adapter_config: [
      schema: Medlum.Reports.ReportTemplate,
      repo: Medlum.Repo,
      update_changeset: &MedlumWeb.Admin.Db.ChangesetHelpers.report_template_changeset/3,
      create_changeset: &MedlumWeb.Admin.Db.ChangesetHelpers.report_template_changeset/3,
      item_query: &__MODULE__.item_query/3
    ],
    pubsub: [server: MedlumWeb.PubSub, topic: "report_templates"]

  import Ecto.Query
  import MedlumWeb.Admin.Db.BackpexHelpers

  def item_query(query, _live_action, _assigns) do
    from(q in query, preload: [:tenant])
  end

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
        live_resource: MedlumWeb.Admin.Db.TenantLive
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
