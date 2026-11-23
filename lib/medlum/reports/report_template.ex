defmodule Medlum.Reports.ReportTemplate do
  use Ecto.Schema
  import Ecto.Changeset

  alias Medlum.Tenancy.Tenant
  alias Medlum.Reports.ReportSectionTemplate

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "report_templates" do
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:status, :string, default: "active")
    field(:version, :integer, default: 1)
    field(:default_prompt_options, :map, default: %{})
    field(:ingestion_prompt_template, :string)
    # Template-level system prompt - used as default for sections
    field(:system_prompt, :string)

    belongs_to(:tenant, Tenant)
    has_many(:sections, ReportSectionTemplate, foreign_key: :template_id)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating/updating a report template.

  The `default_prompt_options` map can contain default LLM settings like:
  - temperature, top_p, top_k, max_output_tokens
  - These are used as defaults when section-level values are nil

  The `system_prompt` is the template-level system instruction.
  Sections can override this with their own system_prompt.
  """
  def changeset(template, attrs) do
    template
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :status,
      :version,
      :default_prompt_options,
      :ingestion_prompt_template,
      :system_prompt,
      :tenant_id
    ])
    |> validate_required([:name, :slug, :status, :tenant_id])
    |> unique_constraint([:tenant_id, :slug])
  end
end
