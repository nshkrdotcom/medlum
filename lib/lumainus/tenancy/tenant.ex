defmodule Lumainus.Tenancy.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Tenancy.{TenantDomain, TenantSetting}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenants" do
    field(:name, :string)
    field(:slug, :string)
    field(:status, :string, default: "active")
    field(:primary_domain, :string)
    field(:metadata, :map, default: %{})

    has_many(:domains, TenantDomain)
    has_many(:settings, TenantSetting)

    timestamps(type: :utc_datetime)
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :slug, :status, :primary_domain, :metadata])
    |> validate_required([:name, :slug, :status])
    |> validate_length(:slug, min: 3)
    |> unique_constraint(:slug)
  end
end
