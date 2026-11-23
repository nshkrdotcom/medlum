defmodule MedlumWeb.Admin.Db.UserLive do
  use Backpex.LiveResource,
    layout: {MedlumWeb.AdminLayout, :app},
    adapter_config: [
      schema: Medlum.Accounts.User,
      repo: Medlum.Repo,
      update_changeset: &MedlumWeb.Admin.Db.ChangesetHelpers.user_changeset/3,
      create_changeset: &MedlumWeb.Admin.Db.ChangesetHelpers.user_changeset/3
    ],
    pubsub: [server: MedlumWeb.PubSub, topic: "users"]

  import MedlumWeb.Admin.Db.BackpexHelpers

  @impl Backpex.LiveResource
  def singular_name, do: "User"

  @impl Backpex.LiveResource
  def plural_name, do: "Users"

  @impl Backpex.LiveResource
  def fields do
    [
      id: %{
        module: Backpex.Fields.Text,
        label: "ID",
        readonly: true
      },
      email: %{
        module: Backpex.Fields.Text,
        label: "Email",
        searchable: true
      },
      name: %{
        module: Backpex.Fields.Text,
        label: "Name",
        searchable: true
      },
      role: %{
        module: Backpex.Fields.Select,
        label: "Role",
        options: [
          {"Guest", "guest"},
          {"Doctor", "doctor"},
          {"Admin", "admin"},
          {"System Administrator", "system_administrator"}
        ]
      },
      locale: %{
        module: Backpex.Fields.Text,
        label: "Locale"
      },
      timezone: %{
        module: Backpex.Fields.Text,
        label: "Timezone"
      },
      docling_backend: %{
        module: Backpex.Fields.Select,
        label: "Docling Backend",
        options: [
          {"Local", "local"},
          {"Cloud", "cloud"},
          {"Fast", "fast"}
        ]
      },
      confirmed_at: %{
        module: Backpex.Fields.DateTime,
        label: "Confirmed At",
        readonly: true,
        render: datetime_render()
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
