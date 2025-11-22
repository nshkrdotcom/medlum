defmodule Lumainus.Documents.IngestionIntegrationTest do
  @moduledoc """
  Integration tests for the complete ingestion pipeline.

  These tests require the Docling service to be running and may take
  significant time to complete.
  """

  use Lumainus.DataCase, async: false

  @moduletag :integration
  # 5 min timeout for real conversion
  @moduletag timeout: 300_000

  @docling_available match?({:ok, _}, Lumainus.Docling.health())

  if not @docling_available do
    @moduletag skip: "Docling unavailable"
  end

  alias Lumainus.Documents
  alias Lumainus.Documents.{DocumentUpload, IngestionConfig, IngestionJob}

  # Test fixtures
  defp create_test_tenant do
    slug = "integration-test-tenant-#{System.unique_integer([:positive])}"

    %Lumainus.Tenancy.Tenant{}
    |> Lumainus.Tenancy.Tenant.changeset(%{name: "Integration Test Tenant", slug: slug})
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
      label: "Integration Test",
      status: "active"
    })
    |> Repo.insert!()
  end

  defp create_test_template(tenant) do
    %Lumainus.Reports.ReportTemplate{}
    |> Lumainus.Reports.ReportTemplate.changeset(%{
      tenant_id: tenant.id,
      name: "Test Template",
      description: "For testing",
      status: "active"
    })
    |> Repo.insert!()
  end

  setup do
    tenant = create_test_tenant()
    scope = create_test_scope(tenant)
    patient = create_test_patient(tenant)
    record_set = create_test_record_set(patient)
    template = create_test_template(tenant)

    {:ok,
     tenant: tenant, scope: scope, patient: patient, record_set: record_set, template: template}
  end

  describe "queue system configuration" do
    test "IngestionConfig returns correct values" do
      assert IngestionConfig.conversion_timeout_ms() == 1_200_000
      assert IngestionConfig.max_retries() == 3
      assert IngestionConfig.stale_job_threshold_minutes() == 60
    end

    test "deadline calculation is reasonable" do
      deadline = IngestionConfig.calculate_deadline()
      diff_minutes = DateTime.diff(deadline, DateTime.utc_now(), :minute)

      # Should be at least 20 minutes (one timeout) and less than 2 hours
      assert diff_minutes >= 20
      assert diff_minutes < 120
    end
  end

  describe "job creation" do
    test "queue_ingestion creates job with correct fields", ctx do
      # Create a minimal PDF (just enough to be valid)
      pdf_binary = create_minimal_pdf()

      {:ok, upload} =
        Documents.create_upload(
          ctx.scope,
          ctx.patient,
          ctx.record_set,
          %{
            filename: "test.pdf",
            content_type: "application/pdf",
            byte_size: byte_size(pdf_binary)
          },
          pdf_binary
        )

      {:ok, job} = Documents.queue_ingestion(upload, ctx.template)

      assert job.state == "queued"
      assert job.max_attempts == 3
      assert job.deadline_at != nil
      assert job.oban_job_id != nil

      # Deadline should be in the future
      assert DateTime.compare(job.deadline_at, DateTime.utc_now()) == :gt
    end
  end

  describe "job cancellation" do
    test "can cancel a queued job", ctx do
      pdf_binary = create_minimal_pdf()

      {:ok, upload} =
        Documents.create_upload(
          ctx.scope,
          ctx.patient,
          ctx.record_set,
          %{
            filename: "test.pdf",
            content_type: "application/pdf",
            byte_size: byte_size(pdf_binary)
          },
          pdf_binary
        )

      {:ok, job} = Documents.queue_ingestion(upload, ctx.template)

      # Cancel it
      :ok = Documents.cancel_ingestion_job(job.id)

      cancelled_job = Repo.get!(IngestionJob, job.id)
      assert cancelled_job.cancelled_at != nil
      assert cancelled_job.state == "failed"
      assert cancelled_job.last_error =~ "Cancelled"
    end

    test "cannot cancel already completed job", ctx do
      pdf_binary = create_minimal_pdf()

      {:ok, upload} =
        Documents.create_upload(
          ctx.scope,
          ctx.patient,
          ctx.record_set,
          %{
            filename: "test.pdf",
            content_type: "application/pdf",
            byte_size: byte_size(pdf_binary)
          },
          pdf_binary
        )

      {:ok, job} = Documents.queue_ingestion(upload, ctx.template)

      # Manually complete it
      {:ok, _} = Documents.mark_job_processing(job, 1)
      {:ok, completed_job} = Documents.mark_job_completed(job)

      # Try to cancel
      result = Documents.cancel_ingestion_job(completed_job.id)
      assert result == {:error, :already_completed}
    end
  end

  describe "error recording" do
    test "errors are recorded in history", ctx do
      pdf_binary = create_minimal_pdf()

      {:ok, upload} =
        Documents.create_upload(
          ctx.scope,
          ctx.patient,
          ctx.record_set,
          %{
            filename: "test.pdf",
            content_type: "application/pdf",
            byte_size: byte_size(pdf_binary)
          },
          pdf_binary
        )

      {:ok, job} = Documents.queue_ingestion(upload, ctx.template)

      # Record some errors
      {:ok, job} = Documents.record_job_error(job, 1, :timeout)
      {:ok, job} = Documents.record_job_error(job, 2, :network_error)

      assert length(job.error_history) == 2
      assert Enum.at(job.error_history, 0)["attempt"] == 1
      assert Enum.at(job.error_history, 1)["attempt"] == 2
    end
  end

  describe "retry logic" do
    test "should_retry? respects max attempts", ctx do
      pdf_binary = create_minimal_pdf()

      {:ok, upload} =
        Documents.create_upload(
          ctx.scope,
          ctx.patient,
          ctx.record_set,
          %{
            filename: "test.pdf",
            content_type: "application/pdf",
            byte_size: byte_size(pdf_binary)
          },
          pdf_binary
        )

      {:ok, job} = Documents.queue_ingestion(upload, ctx.template)

      # Should retry when attempts < max
      assert Documents.should_retry?(%{job | attempt_number: 1, max_attempts: 3})
      assert Documents.should_retry?(%{job | attempt_number: 2, max_attempts: 3})

      # Should not retry when at max
      refute Documents.should_retry?(%{job | attempt_number: 3, max_attempts: 3})
    end

    test "should_retry? respects deadline", ctx do
      pdf_binary = create_minimal_pdf()

      {:ok, upload} =
        Documents.create_upload(
          ctx.scope,
          ctx.patient,
          ctx.record_set,
          %{
            filename: "test.pdf",
            content_type: "application/pdf",
            byte_size: byte_size(pdf_binary)
          },
          pdf_binary
        )

      {:ok, job} = Documents.queue_ingestion(upload, ctx.template)

      # Should not retry if deadline passed
      past_deadline = DateTime.add(DateTime.utc_now(), -1, :hour)
      refute Documents.should_retry?(%{job | deadline_at: past_deadline, attempt_number: 1})
    end
  end

  # Helper to create a minimal valid PDF
  defp create_minimal_pdf do
    # Minimal PDF structure
    """
    %PDF-1.4
    1 0 obj
    << /Type /Catalog /Pages 2 0 R >>
    endobj
    2 0 obj
    << /Type /Pages /Kids [3 0 R] /Count 1 >>
    endobj
    3 0 obj
    << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>
    endobj
    4 0 obj
    << /Length 44 >>
    stream
    BT
    /F1 12 Tf
    100 700 Td
    (Test) Tj
    ET
    endstream
    endobj
    xref
    0 5
    0000000000 65535 f
    0000000009 00000 n
    0000000058 00000 n
    0000000115 00000 n
    0000000206 00000 n
    trailer
    << /Size 5 /Root 1 0 R >>
    startxref
    300
    %%EOF
    """
  end
end
