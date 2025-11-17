defmodule Lumainus.Reports.ReportSectionCitation do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Reports.ReportSectionRun
  alias Lumainus.Documents.{DocumentUpload, DocumentChunk}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "report_section_citations" do
    field(:citation_label, :string)
    field(:source_span, :map, default: %{})

    belongs_to(:section_run, ReportSectionRun)
    belongs_to(:document, DocumentUpload)
    belongs_to(:document_chunk, DocumentChunk)

    timestamps(type: :utc_datetime)
  end

  def changeset(citation, attrs) do
    citation
    |> cast(attrs, [
      :citation_label,
      :source_span,
      :section_run_id,
      :document_id,
      :document_chunk_id
    ])
    |> validate_required([:citation_label, :source_span, :section_run_id, :document_id])
  end
end
