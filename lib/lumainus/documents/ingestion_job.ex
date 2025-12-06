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
  @docling_backends ~w(local fast cloud)

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          job_type: String.t() | nil,
          status: String.t(),
          state: String.t(),
          stage: String.t(),
          progress: integer(),
          last_message: String.t() | nil,
          last_error: String.t() | nil,
          attempts: integer(),
          error: map() | nil,
          metadata: map(),
          scheduled_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          timeout_at: DateTime.t() | nil,
          attempt_number: integer(),
          max_attempts: integer(),
          next_retry_at: DateTime.t() | nil,
          deadline_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil,
          archived_at: DateTime.t() | nil,
          error_history: [map()],
          oban_job_id: integer() | nil,
          docling_job_id: String.t() | nil,
          backend: String.t(),
          tenant_id: Ecto.UUID.t() | nil,
          upload_id: Ecto.UUID.t() | nil,
          record_set_id: Ecto.UUID.t() | nil,
          events: Ecto.Association.NotLoaded.t() | list(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

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

    # Robust queue fields
    field(:attempt_number, :integer, default: 1)
    field(:max_attempts, :integer, default: 3)
    field(:next_retry_at, :utc_datetime)
    field(:deadline_at, :utc_datetime)
    field(:cancelled_at, :utc_datetime)
    field(:archived_at, :utc_datetime)
    field(:error_history, {:array, :map}, default: [])
    field(:oban_job_id, :integer)
    field(:docling_job_id, :string)
    field(:backend, :string, default: "local")

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
      :attempt_number,
      :max_attempts,
      :next_retry_at,
      :deadline_at,
      :cancelled_at,
      :archived_at,
      :error_history,
      :oban_job_id,
      :docling_job_id,
      :backend,
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
    |> validate_inclusion(:backend, @docling_backends)
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end

  def stages, do: @stages
  def states, do: @states
end
