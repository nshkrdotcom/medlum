defmodule LumainusWeb.ReportsLiveTest do
  use LumainusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Lumainus.AccountsFixtures

  alias Ecto.Changeset
  alias Lumainus.Accounts.Scope
  alias Lumainus.Documents
  alias Lumainus.Documents.IngestionJob
  alias Lumainus.Reports.ReportRun
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

  test "allows deleting uploads", %{conn: conn, scope: scope} do
    workspace = Reports.workspace(scope)
    pdf = "%PDF-1.4"
    meta = %{filename: "remove.pdf", content_type: "application/pdf", byte_size: byte_size(pdf)}

    {:ok, upload} =
      Documents.create_upload(scope, workspace.patient, workspace.record_set, meta, pdf)

    {:ok, view, _html} = live(conn, ~p"/reports")

    view
    |> element("button[phx-value-doc-id=\"#{upload.id}\"][phx-click=\"select_document\"]")
    |> render_click()

    view
    |> element("button[phx-click=\"delete_document\"][phx-value-doc-id=\"#{upload.id}\"]")
    |> render_click()

    refute render(view) =~ "remove.pdf"
  end

  test "allows editing patient demographics inside modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/reports")

    view
    |> element("button[phx-click=\"open_patient_modal\"]")
    |> render_click()

    params = %{
      "profile" => %{
        "given_name" => "Ada",
        "family_name" => "Lovelace",
        "mrn" => "MRN-4242",
        "date_of_birth" => "1980-04-05"
      }
    }

    view
    |> form("#patient-profile-form", params)
    |> render_submit()

    html = render(view)
    assert html =~ "Ada Lovelace"
    assert html =~ "MRN MRN-4242"
  end

  test "loads sample documents via debug button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/reports")

    refute render(view) =~ "ED Intake"

    view
    |> element("button[phx-click=\"seed_sample_documents\"]")
    |> render_click()

    html = render(view)
    assert html =~ "ED Intake"
    assert html =~ "Diagnostics"
  end

  test "shows inline validation errors for patient profile", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/reports")

    view
    |> element("button[phx-click=\"open_patient_modal\"]")
    |> render_click()

    error_html =
      view
      |> form("#patient-profile-form", %{
        "profile" => %{"mrn" => String.duplicate("1", 70)}
      })
      |> render_change()

    assert error_html =~ "should be at most 64 character(s)"
  end

  test "modal still creates and switches workspaces", %{conn: conn, scope: scope} do
    workspace = Reports.workspace(scope)

    {:ok, view, _html} = live(conn, ~p"/reports")

    view
    |> element("button[phx-click=\"open_patient_modal\"]")
    |> render_click()

    initial_count = view_assign(view, :record_sets) |> length

    view
    |> element("#create-record-set")
    |> render_click()

    assert view_assign(view, :record_sets) |> length == initial_count + 1
    refute view_assign(view, :record_set).id == workspace.record_set.id

    view
    |> element("button[phx-click=\"open_patient_modal\"]")
    |> render_click()

    view
    |> element("button.workspace-item[phx-value-id=\"#{workspace.record_set.id}\"]")
    |> render_click()

    assert view_assign(view, :record_set).id == workspace.record_set.id
  end

  test "patient modal surfaces recent runs and prompts", %{conn: conn, scope: scope} do
    workspace = Reports.workspace(scope)

    %ReportRun{}
    |> ReportRun.changeset(%{
      tenant_id: scope.tenant_id,
      patient_id: workspace.patient.id,
      record_set_id: workspace.record_set.id,
      template_id: workspace.template.id,
      run_type: "full",
      status: "completed",
      started_at: DateTime.utc_now(:second),
      finished_at: DateTime.utc_now(:second)
    })
    |> Repo.insert!()

    {:ok, view, _html} = live(conn, ~p"/reports")

    view
    |> element("button[phx-click=\"open_patient_modal\"]")
    |> render_click()

    html = render(view)
    assert html =~ "Recent runs"
    assert html =~ "Completed"
    assert html =~ "You convert uploaded medical PDFs"
  end

  defp view_assign(view, key) do
    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.fetch!(key)
  end

  test "clicking the same document toggles detail", %{conn: conn, scope: scope} do
    workspace = Reports.workspace(scope)
    pdf = "%PDF-1.4 sample"
    meta = %{filename: "toggle.pdf", content_type: "application/pdf", byte_size: byte_size(pdf)}

    {:ok, upload} =
      Documents.create_upload(scope, workspace.patient, workspace.record_set, meta, pdf)

    {:ok, view, _html} = live(conn, ~p"/reports")

    button =
      element(view, "button[phx-value-doc-id=\"#{upload.id}\"][phx-click=\"select_document\"]")

    render_click(button)
    assert has_element?(view, ".doc-detail-actions")

    render_click(button)
    refute has_element?(view, ".doc-detail-actions")
  end
end
