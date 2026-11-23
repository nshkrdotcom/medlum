defmodule MedlumWeb.Admin.Db.PatientLive do
  use Backpex.LiveResource,
    adapter_config: [
      schema: Medlum.Clinical.Patient,
      repo: Medlum.Repo,
      update_changeset: &MedlumWeb.Admin.Db.ChangesetHelpers.patient_changeset/3,
      create_changeset: &MedlumWeb.Admin.Db.ChangesetHelpers.patient_changeset/3
    ],
    pubsub: [server: MedlumWeb.PubSub, topic: "patients"]

  import MedlumWeb.Admin.Db.BackpexHelpers

  @impl Backpex.LiveResource
  def layout(_assigns), do: {MedlumWeb.AdminLayout, :app}

  @impl Backpex.LiveResource
  def singular_name, do: "Patient"

  @impl Backpex.LiveResource
  def plural_name, do: "Patients"

  @impl Backpex.LiveResource
  def fields do
    [
      id: %{module: Backpex.Fields.Text, label: "ID", readonly: true},
      patient_key: %{module: Backpex.Fields.Text, label: "Patient Key", searchable: true},
      status: %{
        module: Backpex.Fields.Select,
        label: "Status",
        options: [{"Active", "active"}, {"Inactive", "inactive"}, {"Archived", "archived"}]
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
