defmodule Medlum.Documents.IngestionSchemaTest do
  use Medlum.DataCase

  import Medlum.AccountsFixtures

  alias Ecto.{Changeset, UUID}
  alias Medlum.{Documents, Reports}
  alias Medlum.Documents.{IngestionEvent, IngestionJob}

  setup do
    scope = user_scope_fixture()
    Reports.bootstrap_workspace!(scope)
    workspace = Reports.workspace(scope)

    pdf = "%PDF-1.4 example"
    meta = %{filename: "labs.pdf", content_type: "application/pdf", byte_size: byte_size(pdf)}

    {:ok, upload} =
      Documents.create_upload(scope, workspace.patient, workspace.record_set, meta, pdf)

    {:ok, scope: scope, workspace: workspace, upload: upload}
  end

  test "ingestion job defaults stage and progress", %{
    scope: scope,
    workspace: workspace,
    upload: upload
  } do
    attrs = %{
      tenant_id: scope.tenant_id,
      upload_id: upload.id,
      record_set_id: workspace.record_set.id,
      job_type: "pdf_ingest",
      status: "pending"
    }

    changeset = IngestionJob.changeset(%IngestionJob{}, attrs)
    assert changeset.valid?

    job = Changeset.apply_changes(changeset)
    assert job.stage == "queued"
    assert job.progress == 0
  end

  test "ingestion job validates stage inclusion", %{
    scope: scope,
    workspace: workspace,
    upload: upload
  } do
    attrs = %{
      tenant_id: scope.tenant_id,
      upload_id: upload.id,
      record_set_id: workspace.record_set.id,
      job_type: "pdf_ingest",
      status: "pending",
      stage: "bogus"
    }

    changeset = IngestionJob.changeset(%IngestionJob{}, attrs)
    refute changeset.valid?
    assert %{stage: ["is invalid"]} = errors_on(changeset)
  end

  test "ingestion event enforces progress bounds" do
    attrs = %{
      event_type: "queued",
      recorded_at: DateTime.utc_now(:second),
      job_id: UUID.generate(),
      progress: 150
    }

    changeset = IngestionEvent.changeset(%IngestionEvent{}, attrs)
    refute changeset.valid?
    assert %{progress: ["must be less than or equal to 100"]} = errors_on(changeset)
  end

  test "ingestion event allows nil progress" do
    attrs = %{
      event_type: "queued",
      recorded_at: DateTime.utc_now(:second),
      job_id: UUID.generate()
    }

    changeset = IngestionEvent.changeset(%IngestionEvent{}, attrs)
    assert changeset.valid?
  end
end
