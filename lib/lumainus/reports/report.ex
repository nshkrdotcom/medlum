defmodule Lumainus.Reports.Report do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Tenancy.Tenant
  alias Lumainus.Clinical.Patient
  alias Lumainus.Reports.{ReportTemplate, ReportRun, ReportVersion}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "reports" do
    field(:title, :string)
    field(:summary, :string)
    field(:body, :string)
    field(:status, :string, default: "draft")
    field(:published_at, :utc_datetime)

    belongs_to(:tenant, Tenant)
    belongs_to(:patient, Patient)
    belongs_to(:template, ReportTemplate)
    belongs_to(:report_run, ReportRun)
    belongs_to(:superseded_by, __MODULE__)

    has_many(:versions, ReportVersion)

    timestamps(type: :utc_datetime)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :title,
      :summary,
      :body,
      :status,
      :published_at,
      :tenant_id,
      :patient_id,
      :template_id,
      :report_run_id,
      :superseded_by_id
    ])
    |> validate_required([:title, :status, :tenant_id, :patient_id, :template_id])
  end
end
