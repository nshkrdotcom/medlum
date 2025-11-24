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
    field(:poll_interval_ms, :integer, default: 250)
    field(:progress_min_interval_ms, :integer, default: 50)
    field(:singleton, :boolean, default: true)

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :backend,
      :local_url,
      :remote_url,
      :timeout_ms,
      :poll_interval_ms,
      :progress_min_interval_ms,
      :singleton
    ])
    |> validate_required([
      :backend,
      :local_url,
      :timeout_ms,
      :poll_interval_ms,
      :progress_min_interval_ms,
      :singleton
    ])
    |> validate_inclusion(:backend, Enum.map(@backend_values, &to_string/1))
    |> validate_number(:timeout_ms, greater_than: 0)
    |> validate_number(:poll_interval_ms, greater_than: 0)
    |> validate_number(:progress_min_interval_ms, greater_than_or_equal_to: 0)
    |> validate_safe_url(:local_url, allow_loopback: true, label: "Local Docling URL")
    |> validate_safe_url(:remote_url,
      allow_loopback: true,
      allow_nil: true,
      label: "Fast (GPU) Docling URL"
    )
    |> unique_constraint(:singleton)
  end

  def backends, do: @backend_values

  defp validate_safe_url(changeset, field, opts) do
    allow_loopback = Keyword.get(opts, :allow_loopback, false)
    allow_nil = Keyword.get(opts, :allow_nil, false)
    label = Keyword.get(opts, :label, to_string(field))

    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_nil(value) and allow_nil ->
          []

        is_binary(value) ->
          case URI.parse(value) do
            %URI{scheme: "https"} ->
              []

            %URI{scheme: "http", host: host} ->
              if allow_loopback and host in ["localhost", "127.0.0.1"] do
                []
              else
                [{field, "#{label} must use https (http allowed only for localhost/127.0.0.1)"}]
              end

            _ ->
              [{field, "#{label} must be a valid https URL"}]
          end

        true ->
          [{field, "#{label} must be a valid https URL"}]
      end
    end)
  end
end
