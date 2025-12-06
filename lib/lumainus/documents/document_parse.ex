defmodule Lumainus.Documents.DocumentParse do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Documents.DocumentUpload
  alias Lumainus.Clinical.PatientProfile

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          parser: String.t() | nil,
          parsed_text: String.t() | nil,
          structured_metadata: map(),
          extracted_at: DateTime.t() | nil,
          upload_id: Ecto.UUID.t() | nil,
          patient_profile_id: Ecto.UUID.t() | nil,
          chunks: Ecto.Association.NotLoaded.t() | list(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "document_parses" do
    field(:parser, :string)
    field(:parsed_text, :string)
    field(:structured_metadata, :map, default: %{})
    field(:extracted_at, :utc_datetime)

    belongs_to(:upload, DocumentUpload)
    belongs_to(:patient_profile, PatientProfile)

    has_many(:chunks, Lumainus.Documents.DocumentChunk, foreign_key: :parse_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(parse, attrs) do
    parse
    |> cast(attrs, [
      :parser,
      :parsed_text,
      :structured_metadata,
      :extracted_at,
      :upload_id,
      :patient_profile_id
    ])
    |> validate_required([:parser, :extracted_at, :upload_id])
  end
end
