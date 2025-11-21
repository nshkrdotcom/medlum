defmodule Lumainus.Documents.IngestionJob do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Tenancy.Tenant
  alias Lumainus.Documents.DocumentUpload
  alias Lumainus.Clinical.PatientRecordSet

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @stages ~w(queued downloading docling parsing completed failed)
  # Lifecycle states roll up the more granular @stages into coarse job health.
  @states ~w(pending queued running completed failed retrying)

  schema "ingestion_jobs" do
    field(:job_type, :string)
    field(:status, :string, default: "pending")
    field(:state, :string, default: "pending")
    field(:stage, :string, default: "queued")
    field(:progress, :integer, default: 0)
    field(:last_message, :string)
    field(:last_error, :string)
    field(:attempts, :integer, default: 0)
    field(:error, :map)
    field(:metadata, :map, default: %{})
    field(:scheduled_at, :utc_datetime)
    field(:started_at, :utc_datetime)
    field(:finished_at, :utc_datetime)
    field(:timeout_at, :utc_datetime)

    belongs_to(:tenant, Tenant)
    belongs_to(:upload, DocumentUpload)
    belongs_to(:record_set, PatientRecordSet)

    has_many(:events, Lumainus.Documents.IngestionEvent, foreign_key: :job_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :job_type,
      :status,
      :state,
      :stage,
      :progress,
      :last_message,
      :last_error,
      :attempts,
      :error,
      :metadata,
      :scheduled_at,
      :started_at,
      :finished_at,
      :timeout_at,
      :tenant_id,
      :upload_id,
      :record_set_id
    ])
    |> validate_required([
      :tenant_id,
      :upload_id,
      :record_set_id,
      :job_type,
      :status,
      :state,
      :stage
    ])
    |> validate_inclusion(:stage, @stages)
    |> validate_inclusion(:state, @states)
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end

  def stages, do: @stages
  def states, do: @states
end
