defmodule Medlum.Audit.AuditLog do
  use Ecto.Schema
  import Ecto.Changeset

  alias Medlum.Tenancy.Tenant
  alias Medlum.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audit_logs" do
    field(:event_type, :string)
    field(:entity_type, :string)
    field(:entity_id, :binary_id)
    field(:metadata, :map, default: %{})
    field(:recorded_at, :utc_datetime)

    belongs_to(:tenant, Tenant)
    belongs_to(:actor, User, foreign_key: :actor_id, type: :id)

    timestamps(type: :utc_datetime)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :event_type,
      :entity_type,
      :entity_id,
      :metadata,
      :recorded_at,
      :tenant_id,
      :actor_id
    ])
    |> validate_required([:event_type, :entity_type, :tenant_id, :recorded_at])
  end
end
