defmodule LumainusWeb.Admin.Db.PatientLive do
  use Backpex.LiveResource,
    layout: {LumainusWeb.AdminLayout, :app},
    adapter_config: [
      schema: Lumainus.Clinical.Patient,
      repo: Lumainus.Repo,
      update_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.patient_changeset/3,
      create_changeset: &LumainusWeb.Admin.Db.ChangesetHelpers.patient_changeset/3
    ],
    pubsub: [server: LumainusWeb.PubSub, topic: "patients"]

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
        live_resource: LumainusWeb.Admin.Db.TenantLive
      },
      inserted_at: %{module: Backpex.Fields.DateTime, label: "Created At", readonly: true},
      updated_at: %{module: Backpex.Fields.DateTime, label: "Updated At", readonly: true}
    ]
  end
end
