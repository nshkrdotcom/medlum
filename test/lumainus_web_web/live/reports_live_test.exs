defmodule LumainusWeb.ReportsLiveTest do
  use LumainusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Lumainus.AccountsFixtures

  alias Ecto.Changeset
  alias Lumainus.Accounts.Scope
  alias Lumainus.Documents
  alias Lumainus.Documents.IngestionJob
  alias Lumainus.{Repo, Reports}

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = Repo.update(Changeset.change(user, role: "doctor"))
    scope = Scope.for_user(user)
    Reports.bootstrap_workspace!(scope)

    conn = log_in_user(conn, user)

    {:ok, conn: conn, scope: scope}
  end

  test "renders ingestion progress and reacts to updates", %{conn: conn, scope: scope} do
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
      progress: 5,
      message: "Queued"
    )

    {:ok, view, html} = live(conn, ~p"/reports")

    assert html =~ "queued"
    assert html =~ "Queued"

    send(
      view.pid,
      {:job_progress, workspace.record_set.id,
       %{upload_id: upload.id, stage: "docling", progress: 40, last_message: "Docling"}}
    )

    html = render(view)
    assert html =~ "Docling"
    assert html =~ "40%"
  end
end
