defmodule Lumainus.Clinical.Patient do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Accounts.User
  alias Lumainus.Tenancy.Tenant
  alias Lumainus.Clinical.{PatientProfile, PatientRecordSet}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "patients" do
    field(:patient_key, :string)
    field(:status, :string, default: "active")

    belongs_to(:tenant, Tenant)
    belongs_to(:created_by_user, User, type: :id)
    belongs_to(:current_profile, PatientProfile)

    has_many(:profiles, PatientProfile)
    has_many(:record_sets, PatientRecordSet)
    has_many(:notes, Lumainus.Clinical.PatientNote)

    timestamps(type: :utc_datetime)
  end

  def changeset(patient, attrs) do
    patient
    |> cast(attrs, [:patient_key, :status, :tenant_id, :current_profile_id, :created_by_user_id])
    |> validate_required([:tenant_id, :patient_key, :status])
    |> unique_constraint([:tenant_id, :patient_key])
  end
end
