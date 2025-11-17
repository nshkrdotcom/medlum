defmodule Lumainus.Clinical.PatientProfile do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Clinical.Patient

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "patient_profiles" do
    field(:given_name, :string)
    field(:family_name, :string)
    field(:mrn, :string)
    field(:date_of_birth, :date)
    field(:sex, :string)
    field(:structured_metadata, :map, default: %{})
    field(:effective_at, :utc_datetime)
    field(:superseded_at, :utc_datetime)
    field(:parsed_from_upload_id, :binary_id)

    belongs_to(:patient, Patient)

    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :patient_id,
      :given_name,
      :family_name,
      :mrn,
      :date_of_birth,
      :sex,
      :structured_metadata,
      :effective_at,
      :superseded_at,
      :parsed_from_upload_id
    ])
    |> validate_required([:patient_id, :effective_at])
  end
end
