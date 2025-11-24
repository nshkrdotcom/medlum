defmodule Lumainus.Docling.Setting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @backend_values ~w(local fast remote vast_ai)a

  schema "docling_settings" do
    field(:backend, :string, default: "local")
    field(:local_url, :string)
    field(:remote_url, :string)
    field(:timeout_ms, :integer)
    field(:poll_interval_ms, :integer)
    field(:singleton, :boolean, default: true)

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:backend, :local_url, :remote_url, :timeout_ms, :poll_interval_ms, :singleton])
    |> validate_required([:backend, :local_url, :timeout_ms, :poll_interval_ms, :singleton])
    |> validate_inclusion(:backend, Enum.map(@backend_values, &to_string/1))
    |> validate_number(:timeout_ms, greater_than: 0)
    |> validate_number(:poll_interval_ms, greater_than: 0)
    |> unique_constraint(:singleton)
  end

  def backends, do: @backend_values
end
