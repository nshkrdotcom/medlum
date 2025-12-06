defmodule Lumainus.Reports.SectionRunWorkerTest do
  use Lumainus.DataCase

  import Lumainus.AccountsFixtures

  alias Lumainus.Documents
  alias Lumainus.Documents.{DocumentChunk, DocumentParse, DocumentUpload}
  alias Lumainus.Reports
  alias Lumainus.Reports.{ReportSectionCitation, ReportSectionRun}
  alias Lumainus.Repo

  setup do
    scope = user_scope_fixture()
    Reports.bootstrap_workspace!(scope)
    workspace = Reports.workspace(scope)

    {:ok, scope: scope, workspace: workspace}
  end

  test "section run worker records citations with chunk provenance", %{
    scope: scope,
    workspace: workspace
  } do
    upload = insert_upload_with_chunks(scope, workspace)
    template = workspace.template
    [section | _] = template.sections

    assert {:ok, _run} =
             Reports.run_sections(
               scope,
               workspace.patient,
               workspace.record_set,
               template,
               [section.id]
             )

    runs = Repo.all(ReportSectionRun)
    IO.puts("DEBUG: Found #{length(runs)} section runs:")

    for r <- runs do
      IO.puts(
        "  - id=#{r.id} status=#{r.status} section_template_id=#{r.section_template_id} report_run_id=#{r.report_run_id}"
      )
    end

    run =
      ReportSectionRun
      |> Repo.one!()

    assert run.status == "completed", "section run failed: #{inspect(run.error)}"

    citation =
      ReportSectionCitation
      |> Repo.one!()

    assert citation.document_id == upload.id
    assert citation.document_chunk_id
    assert citation.source_span["line_start"] == 1
    assert citation.source_span["mock_id"]
  end

  defp insert_upload_with_chunks(scope, workspace) do
    pdf = "%PDF-1.4"
    meta = %{filename: "lines.pdf", content_type: "application/pdf", byte_size: byte_size(pdf)}

    {:ok, upload} =
      Documents.create_upload(scope, workspace.patient, workspace.record_set, meta, pdf)

    upload =
      upload
      |> DocumentUpload.changeset(%{
        metadata: Map.put(upload.metadata, "mock_id", "doc-001"),
        raw_blob: pdf
      })
      |> Repo.update!()

    parse =
      %DocumentParse{}
      |> DocumentParse.changeset(%{
        upload_id: upload.id,
        parser: "test",
        parsed_text: "Line one\nLine two",
        structured_metadata: %{},
        extracted_at: DateTime.utc_now(:second)
      })
      |> Repo.insert!()

    %DocumentChunk{}
    |> DocumentChunk.changeset(%{
      parse_id: parse.id,
      position: 0,
      content: "Line one detail",
      token_count: 3,
      line_start: 1,
      line_end: 1
    })
    |> Repo.insert!()

    upload
  end
end
