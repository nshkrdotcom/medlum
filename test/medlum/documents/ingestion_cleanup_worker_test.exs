defmodule Medlum.Documents.IngestionCleanupWorkerTest do
  use Medlum.DataCase

  @moduletag :capture_log

  import Ecto.Query

  alias Medlum.Documents.{IngestionCleanupWorker, IngestionJob}

  # Test fixtures
  defp create_test_tenant do
    slug = "test-tenant-#{System.unique_integer([:positive])}"

    %Medlum.Tenancy.Tenant{}
    |> Medlum.Tenancy.Tenant.changeset(%{name: "Test Tenant", slug: slug})
    |> Repo.insert!()
  end

  defp create_test_patient(tenant) do
    %Medlum.Clinical.Patient{}
    |> Medlum.Clinical.Patient.changeset(%{
      tenant_id: tenant.id,
      patient_key: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end

  defp create_test_record_set(patient) do
    %Medlum.Clinical.PatientRecordSet{}
    |> Medlum.Clinical.PatientRecordSet.changeset(%{
      tenant_id: patient.tenant_id,
      patient_id: patient.id,
      label: "Test Record Set",
      status: "active"
    })
    |> Repo.insert!()
  end

  defp create_test_upload(tenant, patient, record_set) do
    %Medlum.Documents.DocumentUpload{}
    |> Medlum.Documents.DocumentUpload.changeset(%{
      tenant_id: tenant.id,
      patient_id: patient.id,
      record_set_id: record_set.id,
      filename: "test.pdf",
      content_type: "application/pdf",
      byte_size: 1024,
      status: "pending",
      document_kind: "Clinical PDF",
      raw_blob: "fake pdf content"
    })
    |> Repo.insert!()
  end

  defp create_test_job(tenant, upload, record_set, attrs) do
    base_attrs = %{
      tenant_id: tenant.id,
      upload_id: upload.id,
      record_set_id: record_set.id,
      job_type: "docling",
      status: "pending",
      state: "queued",
      stage: "queued"
    }

    %IngestionJob{}
    |> IngestionJob.changeset(Map.merge(base_attrs, attrs))
    |> Repo.insert!()
  end

  setup do
    tenant = create_test_tenant()
    patient = create_test_patient(tenant)
    record_set = create_test_record_set(patient)
    upload = create_test_upload(tenant, patient, record_set)

    {:ok, tenant: tenant, patient: patient, record_set: record_set, upload: upload}
  end

  describe "perform/1" do
    test "cleans up stale jobs", %{tenant: tenant, upload: upload, record_set: record_set} do
      # Create a stale job (stuck in running state)
      stale_job =
        create_test_job(tenant, upload, record_set, %{
          state: "running",
          status: "processing"
        })

      # Manually set updated_at to past
      stale_time = DateTime.add(DateTime.utc_now(), -120, :minute)

      from(j in IngestionJob, where: j.id == ^stale_job.id)
      |> Repo.update_all(set: [updated_at: stale_time])

      # Run cleanup
      :ok = IngestionCleanupWorker.perform(%Oban.Job{})

      # Job should be marked as failed
      updated_job = Repo.get!(IngestionJob, stale_job.id)
      assert updated_job.state == "failed"
      assert updated_job.last_error =~ "stale"
    end

    test "archives old completed jobs", %{tenant: tenant, upload: upload, record_set: record_set} do
      # Create an old completed job
      old_job =
        create_test_job(tenant, upload, record_set, %{
          state: "completed",
          status: "completed",
          finished_at: DateTime.add(DateTime.utc_now(), -10, :day)
        })

      # Run cleanup
      :ok = IngestionCleanupWorker.perform(%Oban.Job{})

      # Job should be archived
      updated_job = Repo.get!(IngestionJob, old_job.id)
      assert updated_job.archived_at != nil
    end

    test "does not archive recent completed jobs", %{
      tenant: tenant,
      upload: upload,
      record_set: record_set
    } do
      # Create a recently completed job
      recent_job =
        create_test_job(tenant, upload, record_set, %{
          state: "completed",
          status: "completed",
          finished_at: DateTime.utc_now()
        })

      # Run cleanup
      :ok = IngestionCleanupWorker.perform(%Oban.Job{})

      # Job should NOT be archived
      updated_job = Repo.get!(IngestionJob, recent_job.id)
      assert updated_job.archived_at == nil
    end

    test "does not affect healthy running jobs", %{
      tenant: tenant,
      upload: upload,
      record_set: record_set
    } do
      # Create a recently started job
      healthy_job =
        create_test_job(tenant, upload, record_set, %{
          state: "running",
          status: "processing"
        })

      # Run cleanup
      :ok = IngestionCleanupWorker.perform(%Oban.Job{})

      # Job should still be running
      updated_job = Repo.get!(IngestionJob, healthy_job.id)
      assert updated_job.state == "running"
      assert updated_job.last_error == nil
    end
  end
end
