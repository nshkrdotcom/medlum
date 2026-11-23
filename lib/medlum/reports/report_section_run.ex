defmodule Medlum.Reports.ReportSectionRun do
  use Ecto.Schema
  import Ecto.Changeset

  alias Medlum.Reports.{ReportRun, ReportSectionTemplate}
  alias Medlum.AI.LlmInvocation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "report_section_runs" do
    field(:status, :string, default: "pending")
    field(:prompt_inputs, :map, default: %{})
    field(:output_markdown, :string)
    field(:output_object, :map)
    field(:confidence_score, :float)
    field(:inline_citations, :map, default: %{})
    field(:provenance_graph, :map)
    field(:error, :map)

    belongs_to(:report_run, ReportRun)
    belongs_to(:section_template, ReportSectionTemplate)
    belongs_to(:llm_invocation, LlmInvocation)

    has_many(:citations, Medlum.Reports.ReportSectionCitation, foreign_key: :section_run_id)
    has_many(:feedback, Medlum.Reports.ReportSectionFeedback, foreign_key: :section_run_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(section_run, attrs) do
    section_run
    |> cast(attrs, [
      :status,
      :prompt_inputs,
      :output_markdown,
      :output_object,
      :confidence_score,
      :inline_citations,
      :provenance_graph,
      :error,
      :report_run_id,
      :section_template_id,
      :llm_invocation_id
    ])
    |> validate_required([:report_run_id, :section_template_id, :status])
  end
end
