defmodule LumainusWeb.Admin.Db.TenantLive do
  use Backpex.LiveResource,
    layout: {LumainusWeb.AdminLayout, :app},
    adapter_config: [
      schema: Lumainus.Tenancy.Tenant,
      repo: Lumainus.Repo,
      update_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.tenant_changeset/3,
      create_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.tenant_changeset/3
    ],
    pubsub: [server: LumainusWeb.PubSub, topic: "tenants"]

  @impl Backpex.LiveResource
  def singular_name, do: "Tenant"

  @impl Backpex.LiveResource
  def plural_name, do: "Tenants"

  @impl Backpex.LiveResource
  def fields do
    [
      id: %{module: Backpex.Fields.Text, label: "ID", readonly: true},
      name: %{module: Backpex.Fields.Text, label: "Name", searchable: true},
      slug: %{module: Backpex.Fields.Text, label: "Slug", searchable: true},
      status: %{
        module: Backpex.Fields.Select,
        label: "Status",
        options: [{"Active", "active"}, {"Inactive", "inactive"}, {"Suspended", "suspended"}]
      },
      primary_domain: %{module: Backpex.Fields.Text, label: "Primary Domain"},
      inserted_at: %{module: Backpex.Fields.DateTime, label: "Created At", readonly: true},
      updated_at: %{module: Backpex.Fields.DateTime, label: "Updated At", readonly: true}
    ]
  end
end
