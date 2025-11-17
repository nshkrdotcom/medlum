defmodule Lumainus.Reports.ReportTemplate do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Tenancy.Tenant
  alias Lumainus.Reports.ReportSectionTemplate

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

    belongs_to(:tenant, Tenant)
    has_many(:sections, ReportSectionTemplate, foreign_key: :template_id)

    timestamps(type: :utc_datetime)
  end

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
      :tenant_id
    ])
    |> validate_required([:name, :slug, :status, :tenant_id])
    |> unique_constraint([:tenant_id, :slug])
  end
end
