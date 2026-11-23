defmodule Medlum.Conversion.Infrastructure.BackendRouter do
  @moduledoc """
  Routes processing profiles to available backends.

  ## Configuration

  Backend URLs and profile mappings are stored in the database via `Medlum.Docling.Settings`.
  This allows administrators to configure backends at runtime through the admin UI.

  Falls back to application config if database is unavailable.

  ## Selection Algorithm

  1. Get backends configured for profile (from DB settings)
  2. Filter by health (healthy or unknown, not unhealthy)
  3. Filter by circuit breaker (closed or half-open, not open)
  4. Sort by: breaker state priority, then latency
  5. Return first available, or :service_unavailable

  ## Usage

      {:ok, backend} = BackendRouter.route(:standard)
      backends = BackendRouter.backends_for_profile(:enhanced)
  """

  alias Medlum.Conversion.CloudStatus
  alias Medlum.Conversion.Infrastructure.HealthManager
  alias Medlum.Conversion.Infrastructure.Resilience.CircuitBreaker
  alias Medlum.Conversion.Backends.{LocalBackend, CloudBackend}
  alias Medlum.Docling.Settings

  @type backend_info :: %{
          name: atom(),
          module: module(),
          endpoint: String.t() | nil,
          backend_type: :local | :cloud
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Route a profile to the best available backend.

  ## Options

  - `:health_manager` — HealthManager process name (default: HealthManager)
  - `:circuit_breaker_fn` — Function to get breaker state (for testing)

  ## Returns

  - `{:ok, backend_info}` — Successfully routed
  - `{:error, :service_unavailable}` — No backends available
  """
  @spec route(atom(), keyword()) :: {:ok, backend_info()} | {:error, :service_unavailable}
  def route(profile, opts \\ []) do
    health_manager = Keyword.get(opts, :health_manager, HealthManager)
    circuit_breaker_fn = Keyword.get(opts, :circuit_breaker_fn, &CircuitBreaker.state/1)

    profile
    |> backends_for_profile()
    |> filter_available(health_manager, circuit_breaker_fn)
    |> sort_by_preference(health_manager, circuit_breaker_fn)
    |> select_best()
  end

  @doc """
  Get all backends configured for a profile.

  Reads from database settings via `Medlum.Docling.Settings`.
  """
  @spec backends_for_profile(atom()) :: [backend_info()]
  def backends_for_profile(profile) do
    {:ok, setting} = Settings.fetch_or_init()
    profile_backends = get_profile_backends(setting, profile)

    profile_backends
    |> Enum.map(&build_backend_from_settings(&1, setting))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Get all configured backends (for HealthManager).

  Reads from database settings.
  """
  @spec all_backends() :: [backend_info()]
  def all_backends do
    {:ok, setting} = Settings.fetch_or_init()

    all_backend_names()
    |> Enum.map(&build_backend_from_settings(&1, setting))
    |> Enum.reject(&is_nil/1)
  end

  # ============================================================================
  # Private Functions - Settings Integration
  # ============================================================================

  defp get_profile_backends(setting, profile) do
    profiles = setting.v2_profile_backends || default_profiles()
    Map.get(profiles, to_string(profile), [])
  end

  defp build_backend_from_settings(backend_name, setting) do
    endpoint = get_endpoint_from_settings(backend_name, setting)
    type = backend_type(backend_name)

    # Skip local backends without endpoints, but allow cloud (gets URL from InstanceManager)
    if endpoint || type == :cloud do
      name = safe_atom(backend_name)

      %{
        name: name,
        module: module_for_type(type),
        endpoint: endpoint,
        backend_type: type
      }
    else
      nil
    end
  end

  defp get_endpoint_from_settings("docker_cpu", s), do: s.docker_cpu_url
  defp get_endpoint_from_settings("docker_gpu", s), do: s.docker_gpu_url
  defp get_endpoint_from_settings("local_cpu", s), do: s.native_cpu_url
  defp get_endpoint_from_settings("native_cpu", s), do: s.native_cpu_url
  defp get_endpoint_from_settings("local_gpu", s), do: s.native_gpu_url
  defp get_endpoint_from_settings("native_gpu", s), do: s.native_gpu_url
  defp get_endpoint_from_settings("cloud", _s), do: nil
  defp get_endpoint_from_settings(_, _), do: nil

  defp backend_type("cloud"), do: :cloud
  defp backend_type(_), do: :local

  defp safe_atom(name) when is_atom(name), do: name

  defp safe_atom(name) when is_binary(name) do
    try do
      String.to_existing_atom(name)
    rescue
      ArgumentError -> String.to_atom(name)
    end
  end

  defp default_profiles do
    %{
      "standard" => ["docker_cpu", "local_cpu"],
      "enhanced" => ["docker_gpu", "local_gpu", "cloud"]
    }
  end

  defp all_backend_names do
    ["docker_cpu", "docker_gpu", "local_cpu", "local_gpu", "cloud"]
  end

  # ============================================================================
  # Private Functions - Module Selection
  # ============================================================================

  defp module_for_type(:local), do: LocalBackend
  defp module_for_type(:cloud), do: CloudBackend

  defp filter_available(backends, health_manager, circuit_breaker_fn) do
    Enum.filter(backends, fn backend ->
      case backend.backend_type do
        :cloud ->
          # Cloud backend uses CloudStatus (wraps InstanceManager) instead of HealthManager
          cloud_available?() and breaker_allows?(backend, circuit_breaker_fn)

        :local ->
          # Local backends use traditional health check
          health_ok?(backend, health_manager) and breaker_allows?(backend, circuit_breaker_fn)
      end
    end)
  end

  defp cloud_available? do
    case CloudStatus.get() do
      %{can_accept_jobs: true} -> true
      _ -> false
    end
  end

  defp health_ok?(backend, health_manager) do
    case HealthManager.status(health_manager, backend.name) do
      :healthy -> true
      :unknown -> true
      :unhealthy -> false
    end
  end

  defp breaker_allows?(backend, circuit_breaker_fn) do
    case circuit_breaker_fn.(backend.name) do
      :closed -> true
      :half_open -> true
      :open -> false
    end
  end

  defp sort_by_preference(backends, health_manager, circuit_breaker_fn) do
    Enum.sort_by(backends, fn backend ->
      breaker_priority = breaker_state_priority(backend.name, circuit_breaker_fn)
      latency = HealthManager.latency(health_manager, backend.name)
      latency_value = normalize_latency(latency)

      {breaker_priority, latency_value}
    end)
  end

  defp breaker_state_priority(backend_name, circuit_breaker_fn) do
    case circuit_breaker_fn.(backend_name) do
      :closed -> 0
      :half_open -> 1
      :open -> 2
    end
  end

  defp normalize_latency(:infinity), do: 999_999_999
  defp normalize_latency(ms) when is_integer(ms), do: ms

  defp select_best([]), do: {:error, :service_unavailable}

  defp select_best([best | _]) do
    # For cloud backends, enrich with dynamic endpoint from CloudStatus
    backend =
      if best.backend_type == :cloud do
        case CloudStatus.get() do
          %{endpoint: endpoint} when is_binary(endpoint) and endpoint != "" ->
            Map.put(best, :endpoint, endpoint)

          _ ->
            best
        end
      else
        best
      end

    {:ok, backend}
  end
end
