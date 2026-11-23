defmodule MedlumWeb.Admin.Db.TenantLive do
  use Backpex.LiveResource,
    adapter_config: [
      schema: Medlum.Tenancy.Tenant,
      repo: Medlum.Repo,
      update_changeset: &MedlumWeb.Admin.Db.ChangesetHelpers.tenant_changeset/3,
      create_changeset: &MedlumWeb.Admin.Db.ChangesetHelpers.tenant_changeset/3
    ],
    pubsub: [server: MedlumWeb.PubSub, topic: "tenants"]

  import MedlumWeb.Admin.Db.BackpexHelpers

  @impl Backpex.LiveResource
  def layout(_assigns), do: {MedlumWeb.AdminLayout, :app}

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
