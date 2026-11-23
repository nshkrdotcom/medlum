defmodule Medlum.Tenancy.TenantDomain do
  use Ecto.Schema
  import Ecto.Changeset

  alias Medlum.Tenancy.Tenant

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenant_domains" do
    field(:host, :string)
    field(:email_domain, :string)
    field(:primary, :boolean, default: false)

    belongs_to(:tenant, Tenant)

    timestamps(type: :utc_datetime)
  end

  def changeset(tenant_domain, attrs) do
    tenant_domain
    |> cast(attrs, [:host, :email_domain, :primary, :tenant_id])
    |> validate_required([:tenant_id])
    |> unique_constraint([:tenant_id, :host])
    |> unique_constraint([:tenant_id, :email_domain])
  end
end
