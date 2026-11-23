defmodule Medlum.Conversion.Infrastructure.HealthManager do
  @moduledoc """
  Periodic health checking for all backends.

  Reads backend configuration from `Medlum.Docling.Settings` (database) as the
  single source of truth, ensuring consistency with `BackendRouter`.

  ## Health States

  - `:healthy` — Recent successful health check
  - `:unhealthy` — Recent failed health check
  - `:unknown` — No recent data (stale > 90s) or unchecked

  ## Configuration

  - `check_interval_ms`: 30_000 ±20% jitter (default)
  - `local_timeout_ms`: 10_000 (default)
  - `cloud_timeout_ms`: 20_000 (default)
  - `stale_threshold_ms`: 90_000 (default)

  ## Usage

      # Start the health manager
      {:ok, pid} = HealthManager.start_link(backends: backends)

      # Check health status
      :healthy = HealthManager.status(:docker_cpu)

      # Get latency
      50 = HealthManager.latency(:docker_cpu)

      # Force immediate check
      HealthManager.check_now(:docker_cpu)

      # Reload backends from Settings (e.g., after admin changes)
      HealthManager.reload_backends()
  """

  use GenServer
  require Logger

  alias Medlum.Conversion.Infrastructure.Resilience.RetryPolicy
  alias Medlum.Docling.Settings

  @default_check_interval_ms 30_000
  @default_stale_threshold_ms 90_000
  @default_jitter_percent 20

  @type health_status :: :healthy | :unhealthy | :unknown

  defstruct [
    :backends,
    :health_states,
    :check_interval_ms,
    :stale_threshold_ms,
    :jitter_percent
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the health manager.

  ## Options

  - `:backends` — Map of backend configs (default: backends_from_settings())
  - `:name` — Process name (default: __MODULE__)
  - `:check_interval_ms` — Interval between checks (default: 30_000)
  - `:stale_threshold_ms` — When to consider data stale (default: 90_000)
  - `:jitter_percent` — Jitter percentage for scheduling (default: 20)
  """
  def start_link(opts \\ []) do
    backends = Keyword.get_lazy(opts, :backends, &backends_from_settings/0)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {backends, opts}, name: name)
  end

  @doc """
  Get health status for a backend.

  Returns `:healthy`, `:unhealthy`, or `:unknown`.
  """
  @spec status(atom() | pid(), atom()) :: health_status()
  def status(server \\ __MODULE__, backend_name) do
    GenServer.call(server, {:status, backend_name})
  end

  @doc """
  Get latency for a backend (ms or :infinity).
  """
  @spec latency(atom() | pid(), atom()) :: non_neg_integer() | :infinity
  def latency(server \\ __MODULE__, backend_name) do
    GenServer.call(server, {:latency, backend_name})
  end

  @doc """
  Force immediate health check for a backend.
  """
  @spec check_now(atom() | pid(), atom()) :: :ok
  def check_now(server \\ __MODULE__, backend_name) do
    GenServer.cast(server, {:check_now, backend_name})
  end

  @doc """
  Reload backend configurations from Settings.

  Call this after Settings are updated to ensure HealthManager
  uses the latest backend URLs.
  """
  @spec reload_backends(atom() | pid()) :: :ok
  def reload_backends(server \\ __MODULE__) do
    GenServer.cast(server, :reload_backends)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init({backends, opts}) do
    state = %__MODULE__{
      backends: backends,
      health_states: %{},
      check_interval_ms: Keyword.get(opts, :check_interval_ms, @default_check_interval_ms),
      stale_threshold_ms: Keyword.get(opts, :stale_threshold_ms, @default_stale_threshold_ms),
      jitter_percent: Keyword.get(opts, :jitter_percent, @default_jitter_percent)
    }

    # Schedule initial checks with staggered starts
    schedule_initial_checks(backends)

    {:ok, state}
  end

  @impl true
  def handle_call({:status, backend_name}, _from, state) do
    result =
      case Map.get(state.health_states, backend_name) do
        nil ->
          :unknown

        %{status: status, checked_at: checked_at} ->
          if stale?(checked_at, state.stale_threshold_ms), do: :unknown, else: status
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:latency, backend_name}, _from, state) do
    result =
      case Map.get(state.health_states, backend_name) do
        nil -> :infinity
        %{latency_ms: nil} -> :infinity
        %{latency_ms: latency} -> latency
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:check_now, backend_name}, state) do
    send(self(), {:check, backend_name})
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reload_backends, state) do
    new_backends = backends_from_settings()

    # Clear health states for backends that changed endpoints
    new_health_states =
      Enum.reduce(new_backends, state.health_states, fn {name, new_config}, acc ->
        old_config = Map.get(state.backends, name)

        if old_config && old_config.endpoint != new_config.endpoint do
          # Endpoint changed - clear health state and trigger immediate check
          send(self(), {:check, name})
          Map.delete(acc, name)
        else
          acc
        end
      end)

    # Schedule checks for any new backends
    new_backend_names = MapSet.new(Map.keys(new_backends))
    old_backend_names = MapSet.new(Map.keys(state.backends))

    MapSet.difference(new_backend_names, old_backend_names)
    |> Enum.each(fn name ->
      delay = :rand.uniform(1_000)
      Process.send_after(self(), {:check, name}, delay)
    end)

    {:noreply, %{state | backends: new_backends, health_states: new_health_states}}
  end

  @impl true
  def handle_info({:check, backend_name}, state) do
    config = Map.get(state.backends, backend_name)

    # Skip cloud backends - they use CloudStatus instead of HealthManager
    if config && config.backend_type != :cloud do
      parent = self()

      Task.start(fn ->
        {status, latency_ms} = perform_health_check(backend_name, config)
        send(parent, {:health_result, backend_name, status, latency_ms})
      end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:health_result, backend_name, status, latency_ms}, state) do
    new_health = %{
      status: status,
      latency_ms: latency_ms,
      checked_at: System.monotonic_time(:millisecond)
    }

    new_states = Map.put(state.health_states, backend_name, new_health)

    emit_health_telemetry(backend_name, status, latency_ms)
    schedule_next_check(backend_name, state.check_interval_ms, state.jitter_percent)

    {:noreply, %{state | health_states: new_states}}
  end

  # ============================================================================
  # Private Functions - Backend Configuration
  # ============================================================================

  @doc false
  def backends_from_settings do
    {:ok, setting} = Settings.fetch_or_init()
    build_backends_from_setting(setting)
  end

  defp build_backends_from_setting(setting) do
    %{
      local_cpu: %{
        module: Medlum.Conversion.Backends.LocalBackend,
        backend_type: :local,
        endpoint: setting.native_cpu_url
      },
      docker_cpu: %{
        module: Medlum.Conversion.Backends.LocalBackend,
        backend_type: :local,
        endpoint: setting.docker_cpu_url
      },
      local_gpu: %{
        module: Medlum.Conversion.Backends.LocalBackend,
        backend_type: :local,
        endpoint: setting.native_gpu_url
      },
      docker_gpu: %{
        module: Medlum.Conversion.Backends.LocalBackend,
        backend_type: :local,
        endpoint: setting.docker_gpu_url
      },
      cloud: %{
        module: Medlum.Conversion.Backends.CloudBackend,
        backend_type: :cloud,
        endpoint: setting.cloud_url
      }
    }
    |> Enum.reject(fn {_name, config} -> is_nil(config.endpoint) or config.endpoint == "" end)
    |> Map.new()
  end

  defp schedule_initial_checks(backends) do
    Enum.each(backends, fn {name, _config} ->
      delay = :rand.uniform(5_000)
      Process.send_after(self(), {:check, name}, delay)
    end)
  end

  # ============================================================================
  # Private Functions - Health Checking
  # ============================================================================

  defp perform_health_check(backend_name, config) do
    start = System.monotonic_time(:millisecond)

    result =
      RetryPolicy.with_retry(
        fn -> do_health_check(config) end,
        max_attempts: 2,
        base_delay_ms: 500
      )

    elapsed = System.monotonic_time(:millisecond) - start

    case result do
      {:ok, _} ->
        Logger.debug("[HealthManager] #{backend_name} healthy (#{elapsed}ms)")
        {:healthy, elapsed}

      {:error, reason} ->
        Logger.debug("[HealthManager] #{backend_name} unhealthy: #{inspect(reason)}")
        {:unhealthy, nil}
    end
  end

  defp do_health_check(config) do
    endpoint = Map.get(config, :endpoint)
    module = Map.get(config, :module)

    cond do
      endpoint && endpoint != "" ->
        case Req.get("#{endpoint}/health", receive_timeout: 10_000, retry: false) do
          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            {:ok, %{"status" => "ok"}}

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, {:http_error, status, body}}

          {:error, %Req.TransportError{reason: reason}} ->
            {:error, {:transport_error, reason}}

          {:error, reason} ->
            {:error, {:transport_error, reason}}
        end

      module && function_exported?(module, :health, 0) ->
        module.health()

      module && function_exported?(module, :health, 1) ->
        module.health(Map.to_list(config))

      true ->
        {:error, :no_health_check_available}
    end
  end

  defp stale?(checked_at, stale_threshold_ms) do
    now = System.monotonic_time(:millisecond)
    now - checked_at > stale_threshold_ms
  end

  defp schedule_next_check(backend_name, check_interval_ms, jitter_percent) do
    jitter = trunc(check_interval_ms * jitter_percent / 100)
    jitter_value = if jitter > 0, do: :rand.uniform(jitter * 2) - jitter, else: 0
    delay = check_interval_ms + jitter_value
    Process.send_after(self(), {:check, backend_name}, delay)
  end

  defp emit_health_telemetry(backend_name, status, latency_ms) do
    case status do
      :healthy ->
        :telemetry.execute(
          [:medlum, :conversion, :health, :checked],
          %{latency_ms: latency_ms || 0},
          %{backend: backend_name}
        )

      :unhealthy ->
        :telemetry.execute(
          [:medlum, :conversion, :health, :unhealthy],
          %{count: 1},
          %{backend: backend_name}
        )
    end
  end
end
