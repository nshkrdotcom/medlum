defmodule Medlum.Accounts.Invitation do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Medlum.Accounts.User
  alias Medlum.Tenancy.Tenant
  alias Medlum.Repo

  schema "invitations" do
    field(:token, :string)
    field(:role, :string)
    field(:email, :string)
    field(:used_at, :utc_datetime)

    belongs_to(:tenant, Tenant, type: :binary_id)
    belongs_to(:created_by, User)

    timestamps(type: :utc_datetime)
  end

  @valid_roles ~w(doctor admin system_administrator)

  @doc false
  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:token, :role, :email, :created_by_id, :tenant_id])
    |> validate_required([:token, :role, :tenant_id])
    |> validate_inclusion(:role, @valid_roles)
    |> validate_format(:email, ~r/@/, message: "must be a valid email")
    |> prevent_duplicate_user_email()
    |> unique_constraint(:token)
  end

  @doc """
  Generates a secure random token for the invitation.
  """
  def generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc """
  Marks an invitation as used.
  """
  def mark_as_used(invitation) do
    change(invitation, used_at: DateTime.utc_now(:second))
  end

  @doc """
  Checks if an invitation is still valid (not used).
  """
  def valid?(invitation) do
    is_nil(invitation.used_at)
  end

  defp prevent_duplicate_user_email(changeset) do
    case get_field(changeset, :email) do
      email when is_binary(email) and email != "" ->
        query =
          from(u in User,
            where: fragment("LOWER(?) = LOWER(?)", u.email, ^email),
            select: 1,
            limit: 1
          )

        if Repo.exists?(query) do
          add_error(changeset, :email, "#{email} has already been taken")
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
