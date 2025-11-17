defmodule Lumainus.Reports.ReportRun do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Tenancy.Tenant
  alias Lumainus.Clinical.Patient
  alias Lumainus.Reports.{ReportTemplate, ReportSectionRun}
  alias Lumainus.AI.LlmInvocation
  alias Lumainus.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "report_runs" do
    field(:run_type, :string, default: "full")
    field(:status, :string, default: "pending")
    field(:started_at, :utc_datetime)
    field(:finished_at, :utc_datetime)

    belongs_to(:tenant, Tenant)
    belongs_to(:patient, Patient)
    belongs_to(:template, ReportTemplate)
    belongs_to(:triggered_by, User, foreign_key: :triggered_by_user_id, type: :id)
    belongs_to(:summary_invocation, LlmInvocation, foreign_key: :summary_invocation_id)

    has_many(:section_runs, ReportSectionRun)

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :run_type,
      :status,
      :started_at,
      :finished_at,
      :tenant_id,
      :patient_id,
      :template_id,
      :triggered_by_user_id,
      :summary_invocation_id
    ])
    |> validate_required([:tenant_id, :patient_id, :template_id, :run_type, :status])
  end
end
