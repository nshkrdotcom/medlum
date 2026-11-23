defmodule Medlum.Documents.IngestionProcessorTest do
  use Medlum.DataCase

  @moduletag :capture_log

  import Medlum.AccountsFixtures

  alias Medlum.Documents.{DocumentUpload, IngestionJob, IngestionProcessor}
  alias Medlum.{Documents, Reports, Repo}
  alias Medlum.Docling.Settings
  alias Plug.Conn

  alias Medlum.Conversion.Infrastructure.HealthManager

  setup do
    bypass = Bypass.open()

    # Handle health check requests from HealthManager
    Bypass.stub(bypass, "GET", "/health", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"status" => "ok"}))
    end)

    # Configure v2 Settings with bypass URL
    {:ok, _} =
      Settings.update_settings(%{
        docker_cpu_url: "http://127.0.0.1:#{bypass.port}",
        v2_profile_backends: %{
          "standard" => ["docker_cpu"],
          "enhanced" => ["docker_cpu"]
        }
      })

    # Reload HealthManager to pick up the new Settings
    HealthManager.reload_backends()
    # Give HealthManager time to trigger health check
    Process.sleep(100)

    {:ok, bypass: bypass}
  end

  test "upload lifecycle stores Docling output", %{bypass: bypass} do
    user = user_fixture()
    scope = user_scope_fixture(user)

    Reports.bootstrap_workspace!(scope)
    workspace = Reports.workspace(scope)

    pdf = "%PDF-1.4 example"
    meta = %{filename: "labs.pdf", content_type: "application/pdf", byte_size: byte_size(pdf)}

    {:ok, upload} =
      Documents.create_upload(scope, workspace.patient, workspace.record_set, meta, pdf)

    # v2 Service creates UUID job_ids - use Bypass.expect/2 to handle all requests
    Bypass.expect(bypass, fn conn ->
      cond do
        conn.method == "POST" and conn.request_path == "/jobs" ->
          Conn.resp(conn, 200, Jason.encode!(%{"job_id" => "accepted", "state" => "queued"}))

        conn.method == "GET" and String.ends_with?(conn.request_path, "/stream") ->
          conn = Conn.put_resp_content_type(conn, "text/event-stream")
          conn = Conn.send_chunked(conn, 200)

          {:ok, conn} =
            Conn.chunk(
              conn,
              "data: {\"state\":\"completed\",\"markdown\":\"# Lab Results\\nLDL elevated\",\"metadata\":{\"page_count\":1,\"source_kind\":\"upload\",\"has_tables\":false}}\n\n"
            )

          conn

        true ->
          Conn.resp(conn, 404, "not found")
      end
    end)

    assert {:ok, job} = Documents.queue_ingestion(upload, workspace.template)

    job = ensure_job_performed(job.id)

    upload =
      wait_for_upload(upload.id, fn record ->
        record.metadata["ingestion_stage"] == "completed"
      end)
      |> Repo.preload(:parses)

    job = Repo.preload(job, :events)
    assert job.stage == "completed"

    assert upload.status == "parsed"
    assert upload.metadata["summary"] =~ "Lab Results"
    assert upload.metadata["page_count"] == 1
    assert upload.ingested_at
    assert [%{parsed_text: "# Lab Results\nLDL elevated"}] = upload.parses
    assert upload.metadata["ingestion_stage"] == "completed"
    assert upload.metadata["ingestion_progress"] == 100

    assert job.stage == "completed"
    assert job.progress == 100
    assert job.last_message =~ "finished"

    stages = Enum.map(job.events, & &1.event_type)
    assert Enum.all?(~w(queued downloading docling parsing completed), &(&1 in stages))
  end

  test "docling failure records failed stage", %{bypass: bypass} do
    user = user_fixture()
    scope = user_scope_fixture(user)

    Reports.bootstrap_workspace!(scope)
    workspace = Reports.workspace(scope)

    pdf = "%PDF-1.4 example"
    meta = %{filename: "labs.pdf", content_type: "application/pdf", byte_size: byte_size(pdf)}

    {:ok, upload} =
      Documents.create_upload(scope, workspace.patient, workspace.record_set, meta, pdf)

    Bypass.expect_once(bypass, "POST", "/jobs", fn conn ->
      Conn.resp(conn, 500, ~s({"error":"nope"}))
    end)

    assert {:ok, job} = Documents.queue_ingestion(upload, workspace.template)

    job = ensure_job_performed(job.id) |> Repo.preload(:events)
    upload = wait_for_upload(upload.id, fn record -> record.metadata["ingestion_stage"] end)

    assert job.status == "failed"
    assert job.stage == "failed"
    assert job.progress == 100
    assert job.last_message =~ "failed"
    assert Enum.any?(job.events, &(&1.event_type == "failed"))

    assert upload.status == "failed"
    assert upload.metadata["ingestion_stage"] == "failed"
    assert upload.metadata["ingestion_progress"] == 100
  end

  defp wait_for_upload(id, predicate, attempts \\ 100)

  defp wait_for_upload(id, _predicate, 0) do
    Repo.get!(DocumentUpload, id)
  end

  defp wait_for_upload(id, predicate, attempts) do
    upload = Repo.get!(DocumentUpload, id)

    if predicate.(upload) do
      upload
    else
      Process.sleep(20)
      wait_for_upload(id, predicate, attempts - 1)
    end
  end

  defp ensure_job_performed(job_id) do
    job = Repo.get!(IngestionJob, job_id)

    cond do
      job.stage in ["completed", "failed"] ->
        job

      true ->
        case IngestionProcessor.process(job.id) do
          :ok -> Repo.get!(IngestionJob, job.id)
          {:error, reason} -> flunk("IngestionProcessor failed: #{inspect(reason)}")
        end
    end
  end
end
