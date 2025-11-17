defmodule Lumainus.Reports.ReportTemplateDocument do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Reports.ReportTemplate

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "report_template_documents" do
    field(:document_kind, :string)
    field(:required, :boolean, default: true)

    belongs_to(:template, ReportTemplate)

    timestamps(type: :utc_datetime)
  end

  def changeset(doc, attrs) do
    doc
    |> cast(attrs, [:document_kind, :required, :template_id])
    |> validate_required([:document_kind, :template_id])
    |> unique_constraint([:template_id, :document_kind])
  end
end
