defmodule Lumainus.Documents.IngestionEvent do
  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Documents.IngestionJob

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ingestion_events" do
    field(:event_type, :string)
    field(:payload, :map, default: %{})
    field(:recorded_at, :utc_datetime)

    belongs_to(:job, IngestionJob)

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :payload, :recorded_at, :job_id])
    |> validate_required([:event_type, :recorded_at, :job_id])
  end
end
