defmodule LumainusWeb.Admin.Db.ReportSectionTemplateLive do
  use Backpex.LiveResource,
    layout: {LumainusWeb.AdminLayout, :app},
    adapter_config: [
      schema: Lumainus.Reports.ReportSectionTemplate,
      repo: Lumainus.Repo,
      update_changeset:
        &LumainusWeb.Admin.Db.ChangesetHelpers.report_section_template_changeset/3,
      create_changeset:
        &LumainusWeb.Admin.Db.ChangesetHelpers.report_section_template_changeset/3,
      item_query: &__MODULE__.item_query/3
    ],
    pubsub: [server: LumainusWeb.PubSub, topic: "report_section_templates"],
    init_order: %{by: :position, direction: :asc}

  import Ecto.Query

  def item_query(query, _live_action, _assigns) do
    from(q in query, preload: [:template])
  end

  @impl Backpex.LiveResource
  def singular_name, do: "Section Template"

  @impl Backpex.LiveResource
  def plural_name, do: "Section Templates"

  @impl Backpex.LiveResource
  def fields do
    [
      id: %{module: Backpex.Fields.Text, label: "ID", readonly: true},
      title: %{module: Backpex.Fields.Text, label: "Title", searchable: true},
      identifier: %{module: Backpex.Fields.Text, label: "Identifier", searchable: true},
      position: %{module: Backpex.Fields.Number, label: "Position"},
      auto_run: %{module: Backpex.Fields.Boolean, label: "Auto Run"},
      provider: %{module: Backpex.Fields.Text, label: "Provider"},
      model: %{module: Backpex.Fields.Text, label: "Model"},
      temperature: %{module: Backpex.Fields.Number, label: "Temperature"},
      max_output_tokens: %{module: Backpex.Fields.Number, label: "Max Tokens"},
      template: %{
        module: Backpex.Fields.BelongsTo,
        label: "Template",
        display_field: :name,
        live_resource: LumainusWeb.Admin.Db.ReportTemplateLive
      },
      inserted_at: %{module: Backpex.Fields.DateTime, label: "Created At", readonly: true},
      updated_at: %{module: Backpex.Fields.DateTime, label: "Updated At", readonly: true}
    ]
  end
end
