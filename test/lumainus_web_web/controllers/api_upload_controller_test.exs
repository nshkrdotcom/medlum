defmodule LumainusWeb.Api.UploadControllerTest do
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

    {:ok, conn: conn, scope: scope, workspace: workspace}
  end

  test "returns upload status with job info", %{conn: conn, scope: scope, workspace: workspace} do
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
      progress: 10
    )

    conn = get(conn, ~p"/api/uploads/#{upload.id}/status")

    assert %{
             "upload" => %{"id" => id, "status" => "queued"},
             "job" => %{"stage" => "queued", "progress" => 10},
             "latest_event" => %{"type" => "queued"}
           } = json_response(conn, 200)

    assert id == upload.id
  end

  test "404 for missing upload", %{conn: conn} do
    conn = get(conn, ~p"/api/uploads/#{UUID.generate()}/status")
    assert %{"error" => _} = json_response(conn, 404)
  end
end
