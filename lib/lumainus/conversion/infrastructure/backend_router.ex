defmodule Lumainus.Conversion.Infrastructure.BackendRouter do
  @moduledoc """
  Routes processing profiles to available backends.

  ## Selection Algorithm

  1. Get backends configured for profile
  2. Filter by health (healthy or unknown, not unhealthy)
  3. Filter by circuit breaker (closed or half-open, not open)
  4. Sort by: breaker state priority, then latency
  5. Return first available, or :service_unavailable

  ## Backend Ordering

  - Closed breaker: priority 0
  - Half-open breaker: priority 1
  - Open breaker: filtered out

  Latency ties broken by config order.

  ## Usage

      # Route a profile to best available backend
      {:ok, backend} = BackendRouter.route(:standard)

      # Get all backends for a profile
      backends = BackendRouter.backends_for_profile(:enhanced)
  """

  alias Lumainus.Conversion.Infrastructure.HealthManager
  alias Lumainus.Conversion.Infrastructure.Resilience.CircuitBreaker

  require Logger

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

  ## Profiles

  - `:standard` — Returns CPU backends (local_cpu, docker_cpu)
  - `:enhanced` — Returns GPU and cloud backends (local_gpu, docker_gpu, cloud)
  """
  @spec backends_for_profile(atom()) :: [backend_info()]
  def backends_for_profile(:standard) do
    config = Application.get_env(:lumainus, :conversion, [])

    [
      %{
        name: :local_cpu,
        module: Lumainus.Conversion.Backends.LocalBackend,
        endpoint: config[:native_cpu_url] || "http://localhost:8040",
        backend_type: :local
      },
      %{
        name: :docker_cpu,
        module: Lumainus.Conversion.Backends.LocalBackend,
        endpoint: config[:docker_cpu_url] || "http://localhost:8042",
        backend_type: :local
      }
    ]
  end

  def backends_for_profile(:enhanced) do
    config = Application.get_env(:lumainus, :conversion, [])

    [
      %{
        name: :local_gpu,
        module: Lumainus.Conversion.Backends.LocalBackend,
        endpoint: config[:native_gpu_url] || "http://localhost:8041",
        backend_type: :local
      },
      %{
        name: :docker_gpu,
        module: Lumainus.Conversion.Backends.LocalBackend,
        endpoint: config[:docker_gpu_url] || "http://localhost:8043",
        backend_type: :local
      },
      %{
        name: :cloud,
        module: Lumainus.Conversion.Backends.CloudBackend,
        endpoint: config[:cloud_url],
        backend_type: :cloud
      }
    ]
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp filter_available(backends, health_manager, circuit_breaker_fn) do
    Enum.filter(backends, fn backend ->
      health_ok?(backend, health_manager) and breaker_allows?(backend, circuit_breaker_fn)
    end)
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
  defp normalize_latency(nil), do: 999_999_999
  defp normalize_latency(ms) when is_integer(ms), do: ms

  defp select_best([]), do: {:error, :service_unavailable}
  defp select_best([best | _]), do: {:ok, best}
end
