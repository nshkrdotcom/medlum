defmodule Lumainus.Clinical.Patients do
  @moduledoc """
  Clinical helpers for working with patient-facing data such as demographics.
  """

  import Ecto.Changeset

  alias Lumainus.Clinical.{Patient, PatientProfile}
  alias Lumainus.Repo

  @doc """
  Returns a changeset for editing a patient's current profile.
  """
  def profile_changeset(%Patient{} = patient, attrs \\ %{}) do
    patient = Repo.preload(patient, :current_profile)

    patient.current_profile
    |> profile_struct_or_new(patient)
    |> build_profile_changeset(attrs)
  end

  @doc """
  Persists edits to the patient's current profile, returning the updated patient.
  """
  def update_profile(%Patient{} = patient, attrs) do
    patient = Repo.preload(patient, :current_profile)
    profile = profile_struct_or_new(patient.current_profile, patient)
    changeset = build_profile_changeset(profile, attrs)

    case persist_profile(profile, changeset) do
      {:ok, profile} ->
        {:ok, %{patient | current_profile: profile}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp profile_struct_or_new(nil, %Patient{} = patient) do
    %PatientProfile{
      patient_id: patient.id,
      effective_at: DateTime.utc_now(:second)
    }
  end

  defp profile_struct_or_new(profile, _patient), do: profile

  defp build_profile_changeset(profile, attrs) do
    profile
    |> PatientProfile.changeset(attrs)
    |> validate_length(:given_name, max: 80)
    |> validate_length(:family_name, max: 80)
    |> validate_length(:mrn, max: 64)
  end

  defp persist_profile(%PatientProfile{id: nil}, changeset), do: Repo.insert(changeset)
  defp persist_profile(_profile, changeset), do: Repo.update(changeset)
end
