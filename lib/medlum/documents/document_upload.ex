defmodule Medlum.Documents.DocumentUpload do
  use Ecto.Schema
  import Ecto.Changeset

  alias Medlum.Tenancy.Tenant
  alias Medlum.Clinical.{Patient, PatientRecordSet}
  alias Medlum.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          document_kind: String.t() | nil,
          filename: String.t() | nil,
          content_type: String.t() | nil,
          byte_size: integer() | nil,
          sha256: String.t() | nil,
          status: String.t(),
          storage_backend: String.t() | nil,
          stored_path: String.t() | nil,
          raw_blob: binary() | nil,
          metadata: map(),
          ingested_at: DateTime.t() | nil,
          tenant_id: Ecto.UUID.t() | nil,
          patient_id: Ecto.UUID.t() | nil,
          record_set_id: Ecto.UUID.t() | nil,
          uploader_id: Ecto.UUID.t() | nil,
          parses: Ecto.Association.NotLoaded.t() | [Medlum.Documents.DocumentParse.t()],
          ingestion_jobs: Ecto.Association.NotLoaded.t() | [Medlum.Documents.IngestionJob.t()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "document_uploads" do
    field(:document_kind, :string)
    field(:filename, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:sha256, :string)
    field(:status, :string, default: "pending")
    field(:storage_backend, :string, default: "postgres")
    field(:stored_path, :string)
    field(:raw_blob, :binary)
    field(:metadata, :map, default: %{})
    field(:ingested_at, :utc_datetime)

    belongs_to(:tenant, Tenant)
    belongs_to(:patient, Patient)
    belongs_to(:record_set, PatientRecordSet)
    belongs_to(:uploader, User, foreign_key: :uploader_id, type: :id)

    has_many(:parses, Medlum.Documents.DocumentParse, foreign_key: :upload_id)
    has_many(:ingestion_jobs, Medlum.Documents.IngestionJob, foreign_key: :upload_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(upload, attrs) do
    upload
    |> cast(attrs, [
      :tenant_id,
      :patient_id,
      :record_set_id,
      :uploader_id,
      :document_kind,
      :filename,
      :content_type,
      :byte_size,
      :sha256,
      :status,
      :storage_backend,
      :stored_path,
      :raw_blob,
      :metadata,
      :ingested_at
    ])
    |> validate_required([:tenant_id, :filename, :status, :record_set_id])
    |> unique_constraint(:sha256, name: :document_uploads_tenant_id_sha256_index)
  end
end
