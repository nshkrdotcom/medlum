defmodule Lumainus.Accounts.Invitation do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Accounts.User

  schema "invitations" do
    field(:token, :string)
    field(:role, :string)
    field(:email, :string)
    field(:used_at, :utc_datetime)

    belongs_to(:created_by, User)

    timestamps(type: :utc_datetime)
  end

  @valid_roles ~w(doctor admin system_administrator)

  @doc false
  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:token, :role, :email, :created_by_id])
    |> validate_required([:token, :role])
    |> validate_inclusion(:role, @valid_roles)
    |> validate_format(:email, ~r/@/, message: "must be a valid email")
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
end
