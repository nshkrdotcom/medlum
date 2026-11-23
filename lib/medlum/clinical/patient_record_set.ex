defmodule Medlum.Clinical.PatientRecordSet do
  @moduledoc """
  Groups all patient artifacts (documents, jobs, reports) under a single umbrella.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Medlum.Tenancy.Tenant
  alias Medlum.Clinical.Patient

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "patient_record_sets" do
    field(:label, :string)
    field(:status, :string, default: "active")
    field(:metadata, :map, default: %{})

    belongs_to(:tenant, Tenant)
    belongs_to(:patient, Patient)

    has_many(:uploads, Medlum.Documents.DocumentUpload, foreign_key: :record_set_id)
    has_many(:ingestion_jobs, Medlum.Documents.IngestionJob, foreign_key: :record_set_id)
    has_many(:report_runs, Medlum.Reports.ReportRun, foreign_key: :record_set_id)
    has_many(:reports, Medlum.Reports.Report, foreign_key: :record_set_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(record_set, attrs) do
    record_set
    |> cast(attrs, [:label, :status, :metadata, :tenant_id, :patient_id])
    |> validate_required([:label, :status, :tenant_id, :patient_id])
  end
end
