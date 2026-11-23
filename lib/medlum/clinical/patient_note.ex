defmodule Medlum.Clinical.PatientNote do
  use Ecto.Schema
  import Ecto.Changeset

  alias Medlum.Clinical.Patient
  alias Medlum.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "patient_notes" do
    field(:body, :string)
    field(:visibility, :string, default: "private")

    belongs_to(:patient, Patient)
    belongs_to(:author, User, foreign_key: :author_user_id, type: :id)

    timestamps(type: :utc_datetime)
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:body, :visibility, :patient_id, :author_user_id])
    |> validate_required([:patient_id, :body, :visibility])
  end
end
