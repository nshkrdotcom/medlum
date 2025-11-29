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
  alias Lumainus.Documents.DocumentParse
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

    parsed_text = "# Parsed content\n\nHello world."

    _parse =
      %DocumentParse{}
      |> DocumentParse.changeset(%{
        upload_id: upload.id,
        parser: "docling",
        parsed_text: parsed_text,
        structured_metadata: %{},
        extracted_at: DateTime.utc_now(:second)
      })
      |> Repo.insert!()

    upload_metadata =
      upload.metadata
      |> Map.put("docling_job_id", docling_job_id)
      |> Map.put("ingestion_stage", "completed")
      |> Map.put("ingestion_state", "completed")
      |> Map.put("ingestion_progress", 100)

    {:ok, _} =
      upload
      |> Ecto.Changeset.change(%{status: "parsed", metadata: upload_metadata})
      |> Repo.update()

    %{conn: conn, docling_job_id: docling_job_id, parsed_text: parsed_text}
  end

  describe "v2 conversion events" do
    test "progress and completion events update documents", %{
      conn: conn,
      docling_job_id: docling_job_id
    } do
      {:ok, view, _html} = live(conn, ~p"/reports")

      Events.broadcast_progress(%{id: docling_job_id}, 42)
      render(view)

      doc_list = view_assign(view, :documents)

      doc =
        Enum.find(doc_list, &(&1.docling_job_id == docling_job_id)) ||
          flunk("doc not found in documents: #{inspect(doc_list)}")

      assert doc.ingestion_progress == 42

      Events.broadcast_completed(%{id: docling_job_id})
      render(view)

      assert view_assign(view, :documents)
             |> Enum.any?(&(&1.docling_job_id == docling_job_id))
    end

    test "selecting a parsed document hydrates cleaned_content", %{
      conn: conn,
      docling_job_id: docling_job_id,
      parsed_text: parsed_text
    } do
      {:ok, view, _html} = live(conn, ~p"/reports")

      doc_list = view_assign(view, :documents)

      doc =
        Enum.find(doc_list, &(&1.docling_job_id == docling_job_id)) ||
          flunk("doc not found in documents: #{inspect(doc_list)}")

      assert doc.cleaned_content == nil

      view
      |> element("button[phx-value-doc-id=\"#{doc.id}\"]")
      |> render_click()

      selected = view_assign(view, :selected_document)
      assert selected.id == doc.id
      assert selected.cleaned_content == parsed_text
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
