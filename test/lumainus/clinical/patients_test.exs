defmodule Lumainus.Clinical.PatientsTest do
  use Lumainus.DataCase

  import Lumainus.AccountsFixtures

  alias Lumainus.Accounts.Scope
  alias Lumainus.Clinical.{Patient, Patients}
  alias Lumainus.{Repo, Reports}

  setup do
    user = user_fixture()
    scope = Scope.for_user(user)
    Reports.bootstrap_workspace!(scope)
    workspace = Reports.workspace(scope)

    {:ok, patient: workspace.patient}
  end

  test "profile_changeset enforces length constraints", %{patient: patient} do
    changeset = Patients.profile_changeset(patient, %{"mrn" => String.duplicate("9", 70)})
    assert "should be at most 64 character(s)" in errors_on(changeset).mrn
  end

  test "update_profile persists changes", %{patient: patient} do
    {:ok, updated} =
      Patients.update_profile(patient, %{
        "given_name" => "Harper",
        "family_name" => "Rowe",
        "mrn" => "MRN-2001",
        "date_of_birth" => "1990-02-03"
      })

    assert updated.current_profile.given_name == "Harper"
    assert updated.current_profile.mrn == "MRN-2001"

    from_repo =
      Repo.get!(Patient, patient.id)
      |> Repo.preload(:current_profile)

    assert from_repo.current_profile.family_name == "Rowe"
  end

  test "update_profile returns errors for invalid data", %{patient: patient} do
    {:error, changeset} =
      Patients.update_profile(patient, %{"given_name" => String.duplicate("a", 200)})

    assert "should be at most 80 character(s)" in errors_on(changeset).given_name
  end
end
