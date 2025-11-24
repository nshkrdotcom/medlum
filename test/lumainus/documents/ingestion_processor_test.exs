defmodule Lumainus.Documents.IngestionProcessorTest do
  use Lumainus.DataCase

  @moduletag :capture_log

  import Lumainus.AccountsFixtures

  alias Lumainus.Documents.{DocumentUpload, IngestionJob, IngestionProcessor}
  alias Lumainus.{Documents, Reports, Repo}
  alias Plug.Conn

  setup do
    bypass = Bypass.open()
    original = Application.get_env(:lumainus, :docling, [])

    new_config =
      original
      |> Keyword.put(:local_url, "http://127.0.0.1:#{bypass.port}")
      |> Keyword.put(:backend, :local)
      |> Keyword.put(:queue_mode, :inline)
      |> Keyword.put(:prefer_sse, false)

    Application.put_env(:lumainus, :docling, new_config)

    on_exit(fn -> Application.put_env(:lumainus, :docling, original) end)

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

    Bypass.expect_once(bypass, "POST", "/jobs", fn conn ->
      body = Jason.encode!(%{"job_id" => "job-1"})
      Conn.resp(conn, 200, body)
    end)

    Bypass.expect_once(bypass, "GET", "/jobs/job-1/status", fn conn ->
      body =
        Jason.encode!(%{
          "job_id" => "job-1",
          "state" => "completed",
          "result" => %{
            "markdown" => "# Lab Results\nLDL elevated",
            "metadata" => %{"page_count" => 1, "source_kind" => "upload", "has_tables" => false}
          }
        })

      Conn.resp(conn, 200, body)
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
