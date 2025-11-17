defmodule Lumainus.Tenancy.TenantSetting do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Tenancy.Tenant

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenant_settings" do
    field(:data, :map, default: %{})
    field(:effective_at, :utc_datetime)
    field(:superseded_at, :utc_datetime)

    belongs_to(:tenant, Tenant)

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:data, :effective_at, :superseded_at, :tenant_id])
    |> validate_required([:tenant_id, :data, :effective_at])
  end
end
