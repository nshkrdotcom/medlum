defmodule Lumainus.Tenancy.UserMembership do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Tenancy.Tenant
  alias Lumainus.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_memberships" do
    field(:role, :string, default: "guest")
    field(:default_scope, :boolean, default: false)

    belongs_to(:tenant, Tenant)
    belongs_to(:user, User, type: :id)

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :default_scope, :tenant_id, :user_id])
    |> validate_required([:tenant_id, :user_id, :role])
    |> validate_inclusion(:role, ["guest", "doctor", "admin", "system_administrator"])
    |> unique_constraint([:tenant_id, :user_id])
  end
end
