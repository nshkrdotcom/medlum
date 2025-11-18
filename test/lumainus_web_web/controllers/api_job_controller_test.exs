defmodule LumainusWeb.Api.JobControllerTest do
  use LumainusWeb.ConnCase

  import Lumainus.AccountsFixtures

  alias Ecto.UUID
  alias Lumainus.Documents
  alias Lumainus.Documents.IngestionJob
  alias Lumainus.{Repo, Reports}

  setup %{conn: conn} do
    scope = user_scope_fixture()
    Reports.bootstrap_workspace!(scope)
    workspace = Reports.workspace(scope)

    pdf = "%PDF-1.4 sample"
    meta = %{filename: "queued.pdf", content_type: "application/pdf", byte_size: byte_size(pdf)}

    {:ok, upload} =
      Documents.create_upload(scope, workspace.patient, workspace.record_set, meta, pdf)

    job =
      %IngestionJob{}
      |> IngestionJob.changeset(%{
        tenant_id: scope.tenant_id,
        upload_id: upload.id,
        record_set_id: workspace.record_set.id,
        job_type: "pdf_ingest",
        status: "pending"
      })
      |> Repo.insert!()
      |> Map.put(:upload, upload)

    Documents.record_job_stage!(job, "queued",
      upload_status: "queued",
      message: "Awaiting worker",
      progress: 5
    )

    {:ok, conn: conn, upload: upload, job: job}
  end

  test "returns job status", %{conn: conn, job: job, upload: upload} do
    upload_id = upload.id
    conn = get(conn, ~p"/api/jobs/#{job.id}/status")

    assert %{
             "job" => %{"stage" => "queued"},
             "upload" => %{"id" => ^upload_id}
           } = json_response(conn, 200)
  end

  test "stream emits sse payload", %{conn: conn, job: job} do
    conn = get(conn, ~p"/api/jobs/#{job.id}/stream", %{once: 1})
    assert conn.status == 200
    assert conn.resp_body =~ "event: progress"
  end

  test "missing job returns 404", %{conn: conn} do
    conn = get(conn, ~p"/api/jobs/#{UUID.generate()}/status")
    assert conn.status == 404
  end
end
