defmodule Lumainus.Documents.DocumentUpload do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Tenancy.Tenant
  alias Lumainus.Clinical.Patient
  alias Lumainus.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
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
    belongs_to(:uploader, User, foreign_key: :uploader_id, type: :id)

    has_many(:parses, Lumainus.Documents.DocumentParse, foreign_key: :upload_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(upload, attrs) do
    upload
    |> cast(attrs, [
      :tenant_id,
      :patient_id,
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
    |> validate_required([:tenant_id, :filename, :status])
  end
end
