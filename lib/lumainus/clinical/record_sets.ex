defmodule Lumainus.Clinical.RecordSets do
  @moduledoc """
  Helpers for managing patient record sets.
  """

  import Ecto.Query, warn: false

  alias Lumainus.Clinical.{Patient, PatientRecordSet}
  alias Lumainus.Repo

  def primary_for_patient(%Patient{} = patient) do
    PatientRecordSet
    |> where([r], r.patient_id == ^patient.id)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> create_primary(patient)
      record_set -> record_set
    end
  end

  defp create_primary(%Patient{} = patient) do
    %PatientRecordSet{}
    |> PatientRecordSet.changeset(%{
      patient_id: patient.id,
      tenant_id: patient.tenant_id,
      label: "Primary Record Set"
    })
    |> Repo.insert!()
  end
end
