defmodule Medlum.Documents.IngestionEvent do
  use Ecto.Schema
  import Ecto.Changeset

  alias Medlum.Documents.IngestionJob

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ingestion_events" do
    field(:event_type, :string)
    field(:payload, :map, default: %{})
    field(:recorded_at, :utc_datetime)
    field(:progress, :integer)
    field(:message, :string)

    belongs_to(:job, IngestionJob)

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :payload, :recorded_at, :job_id, :progress, :message])
    |> validate_required([:event_type, :recorded_at, :job_id])
    |> validate_number(:progress,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
  end
end
