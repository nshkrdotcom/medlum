defmodule Lumainus.Reports.ReportSectionTemplate do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Reports.ReportTemplate

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "report_section_templates" do
    field(:identifier, :string)
    field(:title, :string)
    field(:prompt_template, :string)
    field(:output_schema, :map, default: %{})
    field(:position, :integer, default: 0)
    field(:auto_run, :boolean, default: false)
    field(:provider, :string, default: "google")
    field(:model, :string, default: "gemini-flash-lite-latest")
    field(:temperature, :float)
    field(:max_output_tokens, :integer)
    field(:metadata, :map, default: %{})

    belongs_to(:template, ReportTemplate)

    timestamps(type: :utc_datetime)
  end

  def changeset(section, attrs) do
    section
    |> cast(attrs, [
      :identifier,
      :title,
      :prompt_template,
      :output_schema,
      :position,
      :auto_run,
      :provider,
      :model,
      :temperature,
      :max_output_tokens,
      :metadata,
      :template_id
    ])
    |> validate_required([:identifier, :title, :prompt_template, :template_id])
    |> unique_constraint([:template_id, :identifier])
  end
end
