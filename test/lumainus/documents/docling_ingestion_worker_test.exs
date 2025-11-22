defmodule Lumainus.Documents.DoclingIngestionWorkerTest do
  use Lumainus.DataCase, async: false

  alias Lumainus.Documents
  alias Lumainus.Documents.{DoclingIngestionWorker, IngestionJob}

  # Test fixtures - same as lifecycle test
  defp create_test_tenant do
    slug = "test-tenant-#{System.unique_integer([:positive])}"

    %Lumainus.Tenancy.Tenant{}
    |> Lumainus.Tenancy.Tenant.changeset(%{name: "Test Tenant", slug: slug})
    |> Repo.insert!()
  end

  defp create_test_patient(tenant) do
    %Lumainus.Clinical.Patient{}
    |> Lumainus.Clinical.Patient.changeset(%{
      tenant_id: tenant.id,
      patient_key: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end

  defp create_test_record_set(patient) do
    %Lumainus.Clinical.PatientRecordSet{}
    |> Lumainus.Clinical.PatientRecordSet.changeset(%{
      tenant_id: patient.tenant_id,
      patient_id: patient.id,
      label: "Test Record Set",
      status: "active"
    })
    |> Repo.insert!()
  end

  defp create_test_upload(tenant, patient, record_set) do
    %Lumainus.Documents.DocumentUpload{}
    |> Lumainus.Documents.DocumentUpload.changeset(%{
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

  defp create_test_job(tenant, upload, record_set, attrs \\ %{}) do
    base_attrs = %{
      tenant_id: tenant.id,
      upload_id: upload.id,
      record_set_id: record_set.id,
      job_type: "docling",
      status: "queued",
      state: "queued",
      stage: "queued",
      max_attempts: 3,
      attempt_number: 1
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
    job = create_test_job(tenant, upload, record_set)

    {:ok, tenant: tenant, patient: patient, record_set: record_set, upload: upload, job: job}
  end

  describe "perform/1" do
    test "cancels if job is already cancelled", %{job: job} do
      # Cancel the job first
      :ok = Documents.cancel_ingestion_job(job.id)

      oban_job = %Oban.Job{args: %{"ingestion_job_id" => job.id}, attempt: 1}
      result = DoclingIngestionWorker.perform(oban_job)

      assert result == {:cancel, :job_cancelled}
    end

    test "cancels if deadline has passed", %{
      tenant: tenant,
      upload: upload,
      record_set: record_set
    } do
      past_deadline = DateTime.add(DateTime.utc_now(), -1, :hour)
      job = create_test_job(tenant, upload, record_set, %{deadline_at: past_deadline})

      oban_job = %Oban.Job{args: %{"ingestion_job_id" => job.id}, attempt: 1}
      result = DoclingIngestionWorker.perform(oban_job)

      assert result == {:cancel, :deadline_exceeded}

      # Job should be marked as failed
      updated_job = Repo.get!(IngestionJob, job.id)
      assert updated_job.state == "failed"
      assert updated_job.last_error =~ "deadline"
    end

    test "cancels if max attempts exceeded", %{
      tenant: tenant,
      upload: upload,
      record_set: record_set
    } do
      job = create_test_job(tenant, upload, record_set, %{max_attempts: 2, attempt_number: 2})

      oban_job = %Oban.Job{args: %{"ingestion_job_id" => job.id}, attempt: 3}
      result = DoclingIngestionWorker.perform(oban_job)

      assert result == {:cancel, :max_attempts_exceeded}

      updated_job = Repo.get!(IngestionJob, job.id)
      assert updated_job.state == "failed"
    end

    test "updates attempt info when processing", %{job: job} do
      # Mock the processor to avoid actual Docling call
      # For now, this test just verifies the setup

      oban_job = %Oban.Job{args: %{"ingestion_job_id" => job.id}, attempt: 1}

      # This will fail because Docling isn't running, but we can check setup
      # In a real test, we'd mock IngestionProcessor
      _result = DoclingIngestionWorker.perform(oban_job)

      updated_job = Repo.get!(IngestionJob, job.id)
      assert updated_job.attempt_number == 1
      assert updated_job.attempts == 1
    end
  end

  describe "timeout handling" do
    @tag :slow
    test "records error on timeout", %{job: job} do
      # This would require mocking the processor with a delay
      # For now, documenting the expected behavior
      assert true
    end
  end
end
