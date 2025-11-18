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
    |> order_by([r], asc: r.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> create_primary(patient)
      record_set -> record_set
    end
  end

  def get_for_patient!(%Patient{} = patient, id) do
    PatientRecordSet
    |> where([r], r.id == ^id and r.patient_id == ^patient.id)
    |> Repo.one!()
  end

  def list_for_patient(%Patient{} = patient) do
    PatientRecordSet
    |> where([r], r.patient_id == ^patient.id)
    |> order_by([r], asc: r.inserted_at)
    |> Repo.all()
  end

  def create_record_set(%Patient{} = patient, attrs \\ %{}) do
    defaults = %{
      tenant_id: patient.tenant_id,
      patient_id: patient.id,
      label: Map.get(attrs, :label) || Map.get(attrs, "label") || new_label(patient),
      status: Map.get(attrs, :status) || "active",
      metadata: Map.get(attrs, :metadata) || %{}
    }

    %PatientRecordSet{}
    |> PatientRecordSet.changeset(defaults)
    |> Repo.insert()
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

  defp new_label(patient) do
    count =
      PatientRecordSet
      |> where([r], r.patient_id == ^patient.id)
      |> select([r], count(r.id))
      |> Repo.one()

    "Workspace #{count + 1}"
  end
end
