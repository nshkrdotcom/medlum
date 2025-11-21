defmodule Lumainus.DocumentsTest do
  use Lumainus.DataCase

  import Lumainus.AccountsFixtures

  alias Lumainus.Documents
  alias Lumainus.Documents.DocumentUpload
  alias Lumainus.Reports
  alias Lumainus.Repo

  setup do
    scope = user_scope_fixture()
    Reports.bootstrap_workspace!(scope)
    workspace = Reports.workspace(scope)

    {:ok, scope: scope, workspace: workspace}
  end

  test "create_upload allows duplicates (dedup handled post-parse)", %{
    scope: scope,
    workspace: workspace
  } do
    pdf = "%PDF-1.4"
    meta = %{filename: "lab.pdf", content_type: "application/pdf", byte_size: byte_size(pdf)}

    assert {:ok, %DocumentUpload{} = upload1} =
             Documents.create_upload(scope, workspace.patient, workspace.record_set, meta, pdf)

    assert {:ok, %DocumentUpload{} = upload2} =
             Documents.create_upload(scope, workspace.patient, workspace.record_set, meta, pdf)

    refute upload1.id == upload2.id
  end

  test "delete_upload removes document", %{scope: scope, workspace: workspace} do
    pdf = "%PDF-1.4"
    meta = %{filename: "delete.pdf", content_type: "application/pdf", byte_size: byte_size(pdf)}

    {:ok, upload} =
      Documents.create_upload(scope, workspace.patient, workspace.record_set, meta, pdf)

    assert :ok = Documents.delete_upload(scope, upload.id)
    refute Repo.get(DocumentUpload, upload.id)
  end
end
