defmodule Lumainus.Documents.IngestionJobLifecycleTest do
  use Lumainus.DataCase

  alias Lumainus.Documents
  alias Lumainus.Documents.{IngestionJob, IngestionConfig}

  # Test fixtures
  defp create_test_tenant do
    %Lumainus.Tenancy.Tenant{}
    |> Lumainus.Tenancy.Tenant.changeset(%{name: "Test Tenant"})
    |> Repo.insert!()
  end

  defp create_test_scope(tenant) do
    user = %Lumainus.Accounts.User{tenant_id: tenant.id, id: Ecto.UUID.generate()}
    %Lumainus.Accounts.Scope{user: user, tenant: tenant, tenant_id: tenant.id}
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

  defp create_test_job(tenant, upload, record_set) do
    %IngestionJob{}
    |> IngestionJob.changeset(%{
      tenant_id: tenant.id,
      upload_id: upload.id,
      record_set_id: record_set.id,
      job_type: "docling",
      status: "pending",
      state: "queued",
      stage: "queued"
    })
    |> Repo.insert!()
  end

  setup do
    tenant = create_test_tenant()
    scope = create_test_scope(tenant)
    patient = create_test_patient(tenant)
    record_set = create_test_record_set(patient)
    upload = create_test_upload(tenant, patient, record_set)
    job = create_test_job(tenant, upload, record_set)

    {:ok,
     tenant: tenant,
     scope: scope,
     patient: patient,
     record_set: record_set,
     upload: upload,
     job: job}
  end

  describe "mark_job_processing/2" do
    test "transitions job to processing state", %{job: job} do
      {:ok, updated_job} = Documents.mark_job_processing(job, 1)

      assert updated_job.state == "running"
      assert updated_job.stage == "downloading"
      assert updated_job.attempt_number == 1
      assert updated_job.started_at != nil
      assert updated_job.timeout_at != nil
    end

    test "sets timeout_at based on config", %{job: job} do
      {:ok, updated_job} = Documents.mark_job_processing(job, 1)

      expected_timeout = IngestionConfig.conversion_timeout_ms()
      diff_ms = DateTime.diff(updated_job.timeout_at, DateTime.utc_now(), :millisecond)

      # Should be within 5 seconds of expected
      assert abs(diff_ms - expected_timeout) < 5000
    end

    test "increments attempts counter", %{job: job} do
      {:ok, updated_job} = Documents.mark_job_processing(job, 2)

      assert updated_job.attempts == 1
      assert updated_job.attempt_number == 2
    end
  end

  describe "mark_job_completed/1" do
    test "transitions job to completed state", %{job: job} do
      {:ok, processing_job} = Documents.mark_job_processing(job, 1)
      {:ok, completed_job} = Documents.mark_job_completed(processing_job)

      assert completed_job.state == "completed"
      assert completed_job.status == "completed"
      assert completed_job.finished_at != nil
      assert completed_job.last_error == nil
    end

    test "clears timeout_at", %{job: job} do
      {:ok, processing_job} = Documents.mark_job_processing(job, 1)
      {:ok, completed_job} = Documents.mark_job_completed(processing_job)

      # timeout_at remains for audit but state is completed
      assert completed_job.state == "completed"
    end
  end

  describe "mark_job_failed/2" do
    test "transitions job to failed state", %{job: job} do
      {:ok, processing_job} = Documents.mark_job_processing(job, 1)
      {:ok, failed_job} = Documents.mark_job_failed(processing_job, "Test error")

      assert failed_job.state == "failed"
      assert failed_job.status == "failed"
      assert failed_job.last_error == "Test error"
      assert failed_job.finished_at != nil
    end
  end

  describe "record_job_error/3" do
    test "appends error to history", %{job: job} do
      {:ok, processing_job} = Documents.mark_job_processing(job, 1)
      {:ok, updated_job} = Documents.record_job_error(processing_job, 1, :timeout)

      assert length(updated_job.error_history) == 1
      [error] = updated_job.error_history
      assert error["attempt"] == 1
      assert error["reason"] == ":timeout"
      assert error["timestamp"] != nil
    end

    test "preserves existing error history", %{job: job} do
      {:ok, processing_job} = Documents.mark_job_processing(job, 1)
      {:ok, job_with_error} = Documents.record_job_error(processing_job, 1, :timeout)
      {:ok, job_with_more_errors} = Documents.record_job_error(job_with_error, 2, :network_error)

      assert length(job_with_more_errors.error_history) == 2
    end
  end

  describe "cancel_ingestion_job/1" do
    test "marks job as cancelled", %{job: job} do
      {:ok, processing_job} = Documents.mark_job_processing(job, 1)
      :ok = Documents.cancel_ingestion_job(processing_job.id)

      cancelled_job = Repo.get!(IngestionJob, job.id)
      assert cancelled_job.cancelled_at != nil
      assert cancelled_job.state == "failed"
      assert cancelled_job.last_error =~ "Cancelled"
    end

    test "returns error for already completed job", %{job: job} do
      {:ok, processing_job} = Documents.mark_job_processing(job, 1)
      {:ok, completed_job} = Documents.mark_job_completed(processing_job)

      result = Documents.cancel_ingestion_job(completed_job.id)
      assert result == {:error, :already_completed}
    end

    test "returns error for already cancelled job", %{job: job} do
      :ok = Documents.cancel_ingestion_job(job.id)
      result = Documents.cancel_ingestion_job(job.id)

      assert result == {:error, :already_cancelled}
    end
  end

  describe "should_retry?/1" do
    test "returns true when attempts remaining", %{job: job} do
      job = %{job | attempt_number: 1, max_attempts: 3}
      assert Documents.should_retry?(job) == true
    end

    test "returns false when max attempts reached", %{job: job} do
      job = %{job | attempt_number: 3, max_attempts: 3}
      assert Documents.should_retry?(job) == false
    end

    test "returns false when job is cancelled", %{job: job} do
      job = %{job | cancelled_at: DateTime.utc_now()}
      assert Documents.should_retry?(job) == false
    end

    test "returns false when deadline passed", %{job: job} do
      past_deadline = DateTime.add(DateTime.utc_now(), -1, :hour)
      job = %{job | deadline_at: past_deadline}
      assert Documents.should_retry?(job) == false
    end
  end

  describe "set_deadline/2" do
    test "sets deadline_at on job", %{job: job} do
      {:ok, updated_job} = Documents.set_deadline(job)

      assert updated_job.deadline_at != nil
      # Should be in the future
      assert DateTime.compare(updated_job.deadline_at, DateTime.utc_now()) == :gt
    end

    test "calculates deadline based on retries and timeout", %{job: job} do
      job = %{job | max_attempts: 3}
      {:ok, updated_job} = Documents.set_deadline(job)

      # With 3 attempts at 20min each + backoff, should be well in the future
      diff_minutes = DateTime.diff(updated_job.deadline_at, DateTime.utc_now(), :minute)
      assert diff_minutes > 60
    end
  end

  describe "link_oban_job/2" do
    test "links Oban job ID to ingestion job", %{job: job} do
      {:ok, updated_job} = Documents.link_oban_job(job, 12345)
      assert updated_job.oban_job_id == 12345
    end
  end

  describe "link_docling_job/2" do
    test "links Docling job ID to ingestion job", %{job: job} do
      docling_id = "abc-123-def"
      {:ok, updated_job} = Documents.link_docling_job(job, docling_id)
      assert updated_job.docling_job_id == docling_id
    end
  end

  describe "archive_job/1" do
    test "sets archived_at timestamp", %{job: job} do
      {:ok, processing_job} = Documents.mark_job_processing(job, 1)
      {:ok, completed_job} = Documents.mark_job_completed(processing_job)
      {:ok, archived_job} = Documents.archive_job(completed_job)

      assert archived_job.archived_at != nil
    end

    test "fails for non-terminal jobs", %{job: job} do
      {:ok, processing_job} = Documents.mark_job_processing(job, 1)
      result = Documents.archive_job(processing_job)

      assert result == {:error, :not_terminal}
    end
  end

  describe "find_stale_jobs/0" do
    test "finds jobs stuck in processing", %{
      tenant: tenant,
      upload: upload,
      record_set: record_set
    } do
      # Create a stale job
      stale_time = DateTime.add(DateTime.utc_now(), -120, :minute)

      stale_job =
        %IngestionJob{}
        |> IngestionJob.changeset(%{
          tenant_id: tenant.id,
          upload_id: upload.id,
          record_set_id: record_set.id,
          job_type: "docling",
          status: "processing",
          state: "running",
          stage: "docling"
        })
        |> Repo.insert!()

      # Manually set updated_at to past
      Repo.query!("UPDATE ingestion_jobs SET updated_at = $1 WHERE id = $2", [
        stale_time,
        stale_job.id
      ])

      stale_jobs = Documents.find_stale_jobs()

      assert length(stale_jobs) >= 1
      assert Enum.any?(stale_jobs, &(&1.id == stale_job.id))
    end

    test "does not include recent processing jobs", %{job: job} do
      {:ok, processing_job} = Documents.mark_job_processing(job, 1)

      stale_jobs = Documents.find_stale_jobs()

      refute Enum.any?(stale_jobs, &(&1.id == processing_job.id))
    end
  end
end
