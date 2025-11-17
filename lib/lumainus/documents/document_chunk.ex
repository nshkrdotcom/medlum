defmodule Lumainus.Documents.DocumentChunk do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Documents.DocumentParse

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "document_chunks" do
    field(:position, :integer)
    field(:content, :string)
    field(:token_count, :integer)

    belongs_to(:parse, DocumentParse)

    timestamps(type: :utc_datetime)
  end

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [:position, :content, :token_count, :parse_id])
    |> validate_required([:position, :content, :parse_id])
  end
end
