defmodule LumainusWeb.ReportsLiveV2Test do
  @moduledoc """
  LiveView tests for v2 Conversion event handling in ReportsLive.
  """
  use LumainusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Lumainus.AccountsFixtures

  alias Ecto.Changeset
  alias Lumainus.Accounts.Scope
  alias Lumainus.Conversion.Events
  alias Lumainus.Documents
  alias Lumainus.Reports
  alias Lumainus.Repo

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = Repo.update(Changeset.change(user, role: "doctor"))
    scope = Scope.for_user(user)

    Reports.bootstrap_workspace!(scope)
    workspace = Reports.workspace(scope)
    conn = log_in_user(conn, user)

    pdf = "%PDF-1.4 v2 progress"

    meta = %{
      filename: "v2-progress.pdf",
      content_type: "application/pdf",
      byte_size: byte_size(pdf)
    }

    {:ok, upload} =
      Documents.create_upload(scope, workspace.patient, workspace.record_set, meta, pdf)

    docling_job_id = Ecto.UUID.generate()
    Documents.persist_docling_job_metadata(upload, docling_job_id, profile: :enhanced)

    %{conn: conn, docling_job_id: docling_job_id}
  end

  describe "v2 conversion events" do
    test "progress and completion events update documents", %{
      conn: conn,
      docling_job_id: docling_job_id
    } do
      {:ok, view, _html} = live(conn, ~p"/reports")

      Events.broadcast_progress(%{id: docling_job_id}, 42)
      render(view)

      doc =
        view_assign(view, :documents)
        |> Enum.find(&(&1.docling_job_id == docling_job_id))

      assert doc.ingestion_progress == 42
      assert doc.ingestion_stage == "docling"
      assert doc.ingestion_state == "running"
      assert doc.ingestion_message =~ "Docling"

      Events.broadcast_completed(%{id: docling_job_id})
      render(view)

      assert view_assign(view, :documents)
             |> Enum.any?(&(&1.docling_job_id == docling_job_id))
    end
  end

  defp view_assign(view, key) do
    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.fetch!(key)
  end
end
