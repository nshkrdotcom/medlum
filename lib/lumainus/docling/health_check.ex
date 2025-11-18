defmodule Lumainus.Docling.HealthCheck do
  @moduledoc """
  Persistence for Docling health probe results.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "docling_health_checks" do
    field(:status, :string)
    field(:details, :map, default: %{})
    field(:responded_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  def changeset(check, attrs) do
    check
    |> cast(attrs, [:status, :details, :responded_at])
    |> validate_required([:status])
  end
end
