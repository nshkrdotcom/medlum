defmodule Lumainus.Docling.Setting do
  @moduledoc """
  Schema for Docling runtime configuration stored in the database.

  ## Backend Architecture

  There are 5 backends organized into two user-facing modes:

  ### Local Mode (free) - admin selects one via `active_local_backend`
  - `native_cpu` (port 8040) - Host Python/uvicorn, CPU only
  - `native_gpu` (port 8041) - Host Python/uvicorn, with CUDA
  - `docker_cpu` (port 8042) - Docker container, CPU mode
  - `docker_gpu` (port 8043) - Docker container, GPU mode

  ### Cloud Mode ($$$)
  - `vast_ai` (port 8044) - Vast.ai remote GPU
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  # Valid values for active_local_backend (includes vast_ai for cloud GPU)
  @local_backend_values ~w(native_cpu native_gpu docker_cpu docker_gpu vast_ai)
  # Valid values for default_mode
  @mode_values ~w(local cloud)
  # Legacy backend values (for backward compatibility)
  @legacy_backend_values ~w(local fast remote vast_ai)

  schema "docling_settings" do
    # User-facing default mode
    field(:default_mode, :string, default: "local")
    # Which local backend is active
    field(:active_local_backend, :string, default: "docker_cpu")

    # URLs for all 5 backends
    field(:native_cpu_url, :string)
    field(:native_gpu_url, :string)
    field(:docker_cpu_url, :string)
    field(:docker_gpu_url, :string)
    field(:cloud_url, :string)

    # Legacy fields (for backward compatibility, will be deprecated)
    field(:backend, :string, default: "local")
    field(:local_url, :string)
    field(:remote_url, :string)

    # Timing configuration
    field(:timeout_ms, :integer)
    field(:poll_interval_ms, :integer, default: 250)
    field(:progress_min_interval_ms, :integer, default: 50)

    # v2 Conversion system profile configuration
    field(:v2_profile_backends, :map,
      default: %{
        "standard" => ["docker_cpu", "local_cpu"],
        "enhanced" => ["docker_gpu", "local_gpu", "cloud"]
      }
    )

    # Singleton constraint
    field(:singleton, :boolean, default: true)

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :default_mode,
      :active_local_backend,
      :native_cpu_url,
      :native_gpu_url,
      :docker_cpu_url,
      :docker_gpu_url,
      :cloud_url,
      # Legacy
      :backend,
      :local_url,
      :remote_url,
      # Timing
      :timeout_ms,
      :poll_interval_ms,
      :progress_min_interval_ms,
      # v2 Conversion system
      :v2_profile_backends,
      :singleton
    ])
    |> validate_required([
      :default_mode,
      :active_local_backend,
      :timeout_ms,
      :poll_interval_ms,
      :progress_min_interval_ms,
      :singleton
    ])
    |> validate_inclusion(:default_mode, @mode_values)
    |> validate_inclusion(:active_local_backend, @local_backend_values)
    |> validate_inclusion(:backend, @legacy_backend_values ++ @local_backend_values)
    |> validate_number(:timeout_ms, greater_than: 0)
    |> validate_number(:poll_interval_ms, greater_than: 0)
    |> validate_number(:progress_min_interval_ms, greater_than_or_equal_to: 0)
    # Validate all URL fields
    |> validate_safe_url(:native_cpu_url,
      allow_loopback: true,
      allow_nil: true,
      label: "Native CPU URL"
    )
    |> validate_safe_url(:native_gpu_url,
      allow_loopback: true,
      allow_nil: true,
      label: "Native GPU URL"
    )
    |> validate_safe_url(:docker_cpu_url,
      allow_loopback: true,
      allow_nil: true,
      label: "Docker CPU URL"
    )
    |> validate_safe_url(:docker_gpu_url,
      allow_loopback: true,
      allow_nil: true,
      label: "Docker GPU URL"
    )
    |> validate_safe_url(:cloud_url, allow_loopback: true, allow_nil: true, label: "Cloud URL")
    # Legacy URL validation
    |> validate_safe_url(:local_url, allow_loopback: true, allow_nil: true, label: "Local URL")
    |> validate_safe_url(:remote_url, allow_loopback: true, allow_nil: true, label: "Remote URL")
    |> unique_constraint(:singleton)
  end

  @doc "List of valid local backend values."
  def local_backends, do: @local_backend_values

  @doc "List of valid user mode values."
  def modes, do: @mode_values

  @doc "Legacy backend values for backward compatibility."
  def backends, do: @legacy_backend_values

  defp validate_safe_url(changeset, field, opts) do
    allow_loopback = Keyword.get(opts, :allow_loopback, false)
    allow_nil = Keyword.get(opts, :allow_nil, false)
    label = Keyword.get(opts, :label, to_string(field))

    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_nil(value) and allow_nil ->
          []

        value == "" and allow_nil ->
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
