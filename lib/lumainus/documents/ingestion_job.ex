defmodule Lumainus.Documents.IngestionJob do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Tenancy.Tenant
  alias Lumainus.Documents.DocumentUpload

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ingestion_jobs" do
    field(:job_type, :string)
    field(:status, :string, default: "pending")
    field(:attempts, :integer, default: 0)
    field(:error, :map)
    field(:metadata, :map, default: %{})
    field(:scheduled_at, :utc_datetime)
    field(:started_at, :utc_datetime)
    field(:finished_at, :utc_datetime)

    belongs_to(:tenant, Tenant)
    belongs_to(:upload, DocumentUpload)

    has_many(:events, Lumainus.Documents.IngestionEvent, foreign_key: :job_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :job_type,
      :status,
      :attempts,
      :error,
      :metadata,
      :scheduled_at,
      :started_at,
      :finished_at,
      :tenant_id,
      :upload_id
    ])
    |> validate_required([:tenant_id, :upload_id, :job_type, :status])
  end
end
