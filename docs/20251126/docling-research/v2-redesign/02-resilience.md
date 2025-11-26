# v2 Resilience Patterns

**Date:** November 26, 2025

---

## Overview

The v2 architecture implements comprehensive resilience patterns to handle:

1. **Transient failures** - Network blips, temporary unavailability
2. **Backend outages** - Complete backend failure
3. **Cascade failures** - Preventing one failure from causing others
4. **Resource exhaustion** - Connection limits, memory pressure

---

## Pattern 1: Circuit Breaker

### Purpose

Prevent repeated calls to a failing backend. Fast-fail when a backend is known to be down.

### State Machine

```
        ┌─────────────────────────────────────────┐
        │                                         │
        ▼                                         │
    ┌───────┐   failure_threshold   ┌──────┐     │
    │ CLOSED│──────exceeded────────▶│ OPEN │     │
    │       │                       │      │     │
    └───┬───┘                       └──┬───┘     │
        │                              │         │
        │ success                      │ timeout │
        │                              ▼         │
        │                        ┌──────────┐    │
        │                        │HALF-OPEN │    │
        │                        │          │    │
        │                        └────┬─────┘    │
        │                             │          │
        │        success              │ failure  │
        └─────────────────────────────┘          │
                                      └──────────┘
```

### Implementation

```elixir
defmodule Lumainus.Conversion.Infrastructure.CircuitBreaker do
  @moduledoc """
  Per-backend circuit breaker implementation.
  """

  use GenServer
  require Logger

  alias Lumainus.Conversion.Infrastructure.Telemetry

  @type state :: :closed | :open | :half_open

  defstruct [
    :backend,
    :state,
    :failure_count,
    :success_count,
    :last_failure_at,
    :threshold,
    :timeout_ms,
    :half_open_max_calls
  ]

  # Public API

  @doc "Execute function through circuit breaker"
  @spec call(atom(), (-> result)) :: result | {:error, :circuit_open} when result: any()
  def call(backend, fun) do
    case get_state(backend) do
      :open ->
        Telemetry.circuit_rejected(backend)
        {:error, :circuit_open}

      :half_open ->
        execute_half_open(backend, fun)

      :closed ->
        execute_closed(backend, fun)
    end
  end

  @doc "Check if backend is available (circuit not open)"
  @spec available?(atom()) :: boolean()
  def available?(backend) do
    get_state(backend) != :open
  end

  @doc "Get current circuit state"
  @spec state(atom()) :: state()
  def state(backend) do
    get_state(backend)
  end

  @doc "Manually trip the circuit (for testing/admin)"
  @spec trip(atom()) :: :ok
  def trip(backend) do
    GenServer.call(via(backend), :trip)
  end

  @doc "Manually reset the circuit (for testing/admin)"
  @spec reset(atom()) :: :ok
  def reset(backend) do
    GenServer.call(via(backend), :reset)
  end

  # GenServer Implementation

  def start_link(opts) do
    backend = Keyword.fetch!(opts, :backend)
    GenServer.start_link(__MODULE__, opts, name: via(backend))
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:lumainus, :conversion_circuit_breaker, [])

    state = %__MODULE__{
      backend: opts[:backend],
      state: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure_at: nil,
      threshold: config[:threshold] || 5,
      timeout_ms: config[:timeout_ms] || 30_000,
      half_open_max_calls: config[:half_open_max_calls] || 3
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, %{state: :open} = state) do
    # Check if timeout has elapsed
    if should_transition_to_half_open?(state) do
      new_state = %{state | state: :half_open, success_count: 0}
      Telemetry.circuit_half_open(state.backend)
      {:reply, :half_open, new_state}
    else
      {:reply, :open, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  @impl true
  def handle_call({:record_success}, _from, %{state: :half_open} = state) do
    new_count = state.success_count + 1

    if new_count >= state.half_open_max_calls do
      # Enough successes, close the circuit
      new_state = %{state | state: :closed, failure_count: 0, success_count: 0}
      Telemetry.circuit_closed(state.backend)
      {:reply, :ok, new_state}
    else
      {:reply, :ok, %{state | success_count: new_count}}
    end
  end

  def handle_call({:record_success}, _from, state) do
    # Reset failure count on success in closed state
    {:reply, :ok, %{state | failure_count: 0}}
  end

  @impl true
  def handle_call({:record_failure}, _from, state) do
    new_count = state.failure_count + 1

    if new_count >= state.threshold do
      # Open the circuit
      new_state = %{state |
        state: :open,
        failure_count: new_count,
        last_failure_at: System.monotonic_time(:millisecond)
      }
      Telemetry.circuit_opened(state.backend, new_count)
      Logger.warning("Circuit breaker opened for #{state.backend} after #{new_count} failures")
      {:reply, :ok, new_state}
    else
      {:reply, :ok, %{state | failure_count: new_count}}
    end
  end

  @impl true
  def handle_call(:trip, _from, state) do
    new_state = %{state |
      state: :open,
      last_failure_at: System.monotonic_time(:millisecond)
    }
    Telemetry.circuit_tripped(state.backend)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    new_state = %{state |
      state: :closed,
      failure_count: 0,
      success_count: 0
    }
    Telemetry.circuit_reset(state.backend)
    {:reply, :ok, new_state}
  end

  # Private

  defp via(backend) do
    {:via, Registry, {Lumainus.Conversion.Registry, {:circuit_breaker, backend}}}
  end

  defp get_state(backend) do
    GenServer.call(via(backend), :get_state)
  catch
    :exit, _ -> :closed  # If process not running, assume closed
  end

  defp execute_closed(backend, fun) do
    case safe_execute(fun) do
      {:ok, result} ->
        record_success(backend)
        {:ok, result}

      {:error, reason} = error ->
        record_failure(backend)
        error
    end
  end

  defp execute_half_open(backend, fun) do
    case safe_execute(fun) do
      {:ok, result} ->
        record_success(backend)
        {:ok, result}

      {:error, reason} = error ->
        # Any failure in half-open immediately opens circuit
        GenServer.call(via(backend), :trip)
        error
    end
  end

  defp safe_execute(fun) do
    try do
      case fun.() do
        {:ok, _} = success -> success
        {:error, _} = error -> error
        other -> {:ok, other}
      end
    rescue
      e -> {:error, {:exception, e}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp record_success(backend) do
    GenServer.call(via(backend), {:record_success})
  catch
    :exit, _ -> :ok
  end

  defp record_failure(backend) do
    GenServer.call(via(backend), {:record_failure})
  catch
    :exit, _ -> :ok
  end

  defp should_transition_to_half_open?(state) do
    now = System.monotonic_time(:millisecond)
    now - state.last_failure_at >= state.timeout_ms
  end
end
```

---

## Pattern 2: Retry with Exponential Backoff

### Purpose

Automatically retry transient failures with increasing delays to avoid thundering herd.

### Configuration

```elixir
# Retry configuration
config :lumainus, :conversion_retry,
  max_attempts: 3,
  base_delay_ms: 1_000,
  max_delay_ms: 30_000,
  jitter_factor: 0.2,
  retryable_errors: [:timeout, :econnrefused, :closed, :nxdomain]
```

### Implementation

```elixir
defmodule Lumainus.Conversion.Infrastructure.RetryPolicy do
  @moduledoc """
  Exponential backoff retry policy with jitter.
  """

  require Logger
  alias Lumainus.Conversion.Infrastructure.Telemetry

  @type opts :: [
    max_attempts: pos_integer(),
    base_delay_ms: pos_integer(),
    max_delay_ms: pos_integer(),
    jitter_factor: float(),
    retryable?: (term() -> boolean())
  ]

  @doc """
  Execute function with retry policy.

  ## Options
    * `:max_attempts` - Maximum number of attempts (default: 3)
    * `:base_delay_ms` - Base delay between retries (default: 1000)
    * `:max_delay_ms` - Maximum delay between retries (default: 30000)
    * `:jitter_factor` - Random jitter factor 0.0-1.0 (default: 0.2)
    * `:retryable?` - Function to determine if error is retryable

  ## Examples

      RetryPolicy.with_retry(fn -> http_request() end, max_attempts: 3)
  """
  @spec with_retry((-> result), opts()) :: result when result: any()
  def with_retry(fun, opts \\ []) do
    config = merge_config(opts)
    do_retry(fun, config, 1)
  end

  defp do_retry(fun, config, attempt) do
    case safe_execute(fun) do
      {:ok, result} ->
        if attempt > 1 do
          Telemetry.retry_succeeded(attempt)
        end
        {:ok, result}

      {:error, reason} = error ->
        if attempt < config.max_attempts and retryable?(reason, config) do
          delay = calculate_delay(attempt, config)
          Telemetry.retry_scheduled(attempt, delay, reason)
          Logger.debug("Retry attempt #{attempt + 1} after #{delay}ms due to: #{inspect(reason)}")
          Process.sleep(delay)
          do_retry(fun, config, attempt + 1)
        else
          if attempt > 1 do
            Telemetry.retry_exhausted(attempt, reason)
          end
          error
        end
    end
  end

  defp safe_execute(fun) do
    try do
      case fun.() do
        {:ok, _} = success -> success
        {:error, _} = error -> error
        other -> {:ok, other}
      end
    rescue
      e -> {:error, {:exception, e}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp calculate_delay(attempt, config) do
    # Exponential backoff: base * 2^(attempt-1)
    base_delay = config.base_delay_ms * :math.pow(2, attempt - 1)

    # Cap at max delay
    capped_delay = min(base_delay, config.max_delay_ms)

    # Add jitter
    jitter_range = capped_delay * config.jitter_factor
    jitter = :rand.uniform() * jitter_range * 2 - jitter_range

    max(0, round(capped_delay + jitter))
  end

  defp retryable?(reason, config) do
    case config.retryable? do
      nil -> default_retryable?(reason)
      fun -> fun.(reason)
    end
  end

  defp default_retryable?({:http_error, status, _}) when status >= 500, do: true
  defp default_retryable?({:http_error, 429, _}), do: true  # Rate limited
  defp default_retryable?(:timeout), do: true
  defp default_retryable?(:econnrefused), do: true
  defp default_retryable?(:closed), do: true
  defp default_retryable?(:nxdomain), do: true
  defp default_retryable?({:transport_error, _}), do: true
  defp default_retryable?(_), do: false

  defp merge_config(opts) do
    defaults = Application.get_env(:lumainus, :conversion_retry, [])

    %{
      max_attempts: opts[:max_attempts] || defaults[:max_attempts] || 3,
      base_delay_ms: opts[:base_delay_ms] || defaults[:base_delay_ms] || 1_000,
      max_delay_ms: opts[:max_delay_ms] || defaults[:max_delay_ms] || 30_000,
      jitter_factor: opts[:jitter_factor] || defaults[:jitter_factor] || 0.2,
      retryable?: opts[:retryable?] || defaults[:retryable?]
    }
  end
end
```

---

## Pattern 3: Connection Pool Management

### Purpose

Efficiently manage HTTP connections to backends with proper limits and lifecycle.

### Configuration

```elixir
# Finch connection pool configuration
config :lumainus, Lumainus.Conversion.ConnectionPool,
  pools: %{
    # Local backends share a pool
    local: [
      size: 50,
      count: 4,
      conn_opts: [
        transport_opts: [timeout: 30_000]
      ]
    ],
    # Cloud backend has separate pool
    cloud: [
      size: 25,
      count: 2,
      conn_opts: [
        transport_opts: [timeout: 60_000]
      ]
    ]
  }
```

### Implementation

```elixir
defmodule Lumainus.Conversion.Infrastructure.ConnectionPool do
  @moduledoc """
  HTTP connection pool management for conversion backends.
  """

  @doc """
  Start the connection pools as part of application supervision tree.
  """
  def child_spec(_opts) do
    pools = Application.get_env(:lumainus, __MODULE__, [])[:pools] || default_pools()

    children = Enum.map(pools, fn {name, opts} ->
      {Finch, [name: pool_name(name)] ++ opts}
    end)

    %{
      id: __MODULE__,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}
    }
  end

  @doc "Get pool name for a backend type"
  def pool_for_backend(:local_cpu), do: pool_name(:local)
  def pool_for_backend(:local_docker_cpu), do: pool_name(:local)
  def pool_for_backend(:local_gpu), do: pool_name(:local)
  def pool_for_backend(:local_docker_gpu), do: pool_name(:local)
  def pool_for_backend(:cloud), do: pool_name(:cloud)
  def pool_for_backend(_), do: pool_name(:local)

  @doc "Execute HTTP request through appropriate pool"
  def request(backend, request) do
    pool = pool_for_backend(backend)
    Finch.request(request, pool)
  end

  @doc "Stream HTTP response through appropriate pool"
  def stream(backend, request, acc, fun) do
    pool = pool_for_backend(backend)
    Finch.stream(request, pool, acc, fun)
  end

  defp pool_name(name), do: Module.concat(__MODULE__, name)

  defp default_pools do
    %{
      local: [size: 50, count: 4],
      cloud: [size: 25, count: 2]
    }
  end
end
```

---

## Pattern 4: Health-Aware Routing

### Purpose

Route requests to healthy backends, avoiding backends that are degraded or failing.

### Implementation

```elixir
defmodule Lumainus.Conversion.Infrastructure.HealthManager do
  @moduledoc """
  Manages health state for all backends.
  Provides health-aware backend selection.
  """

  use GenServer
  require Logger

  alias Lumainus.Conversion.Infrastructure.Telemetry

  @check_interval_ms 30_000  # 30 seconds
  @unhealthy_threshold_ms 90_000  # 90 seconds without healthy check

  defstruct [:backends, :check_timer]

  # Public API

  @doc "Check if backend is healthy"
  @spec healthy?(atom()) :: boolean()
  def healthy?(backend) do
    case get_health(backend) do
      %{status: :healthy} -> true
      _ -> false
    end
  end

  @doc "Get backend latency (for routing decisions)"
  @spec latency(atom()) :: non_neg_integer() | :infinity
  def latency(backend) do
    case get_health(backend) do
      %{latency_ms: latency} when is_integer(latency) -> latency
      _ -> :infinity
    end
  end

  @doc "Get all backend health states"
  @spec all_health() :: %{atom() => map()}
  def all_health do
    GenServer.call(__MODULE__, :all_health)
  end

  @doc "Force health check for backend"
  @spec check_now(atom()) :: :ok
  def check_now(backend) do
    GenServer.cast(__MODULE__, {:check_now, backend})
  end

  @doc "Record health check result"
  @spec record_health(atom(), :healthy | :unhealthy, map()) :: :ok
  def record_health(backend, status, details \\ %{}) do
    GenServer.cast(__MODULE__, {:record_health, backend, status, details})
  end

  # GenServer Implementation

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    backends = %{
      local_cpu: initial_health(),
      local_docker_cpu: initial_health(),
      local_gpu: initial_health(),
      local_docker_gpu: initial_health(),
      cloud: initial_health()
    }

    # Schedule periodic health checks
    timer = schedule_checks()

    {:ok, %__MODULE__{backends: backends, check_timer: timer}}
  end

  @impl true
  def handle_call(:all_health, _from, state) do
    {:reply, state.backends, state}
  end

  @impl true
  def handle_call({:get_health, backend}, _from, state) do
    health = Map.get(state.backends, backend, initial_health())

    # Check if health is stale
    health = if stale?(health) do
      %{health | status: :unknown}
    else
      health
    end

    {:reply, health, state}
  end

  @impl true
  def handle_cast({:record_health, backend, status, details}, state) do
    health = %{
      status: status,
      latency_ms: details[:latency_ms],
      last_check_at: System.monotonic_time(:millisecond),
      details: details
    }

    Telemetry.health_recorded(backend, status, details)

    if status == :unhealthy do
      Logger.warning("Backend #{backend} is unhealthy: #{inspect(details)}")
    end

    new_backends = Map.put(state.backends, backend, health)
    {:noreply, %{state | backends: new_backends}}
  end

  @impl true
  def handle_cast({:check_now, backend}, state) do
    spawn(fn -> perform_health_check(backend) end)
    {:noreply, state}
  end

  @impl true
  def handle_info(:periodic_check, state) do
    # Check all backends in parallel
    state.backends
    |> Map.keys()
    |> Enum.each(fn backend ->
      spawn(fn -> perform_health_check(backend) end)
    end)

    timer = schedule_checks()
    {:noreply, %{state | check_timer: timer}}
  end

  # Private

  defp get_health(backend) do
    GenServer.call(__MODULE__, {:get_health, backend})
  catch
    :exit, _ -> initial_health()
  end

  defp initial_health do
    %{
      status: :unknown,
      latency_ms: nil,
      last_check_at: nil,
      details: %{}
    }
  end

  defp stale?(health) do
    case health.last_check_at do
      nil -> true
      last ->
        now = System.monotonic_time(:millisecond)
        now - last > @unhealthy_threshold_ms
    end
  end

  defp schedule_checks do
    Process.send_after(self(), :periodic_check, @check_interval_ms)
  end

  defp perform_health_check(backend) do
    start = System.monotonic_time(:millisecond)

    result = try do
      backend_module(backend).health()
    rescue
      e -> {:error, {:exception, e}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end

    latency = System.monotonic_time(:millisecond) - start

    case result do
      {:ok, details} ->
        record_health(backend, :healthy, Map.put(details, :latency_ms, latency))

      {:error, reason} ->
        record_health(backend, :unhealthy, %{error: reason, latency_ms: latency})
    end
  end

  defp backend_module(:local_cpu), do: Lumainus.Conversion.Infrastructure.Backends.LocalBackend
  defp backend_module(:local_docker_cpu), do: Lumainus.Conversion.Infrastructure.Backends.LocalBackend
  defp backend_module(:local_gpu), do: Lumainus.Conversion.Infrastructure.Backends.LocalBackend
  defp backend_module(:local_docker_gpu), do: Lumainus.Conversion.Infrastructure.Backends.LocalBackend
  defp backend_module(:cloud), do: Lumainus.Conversion.Infrastructure.Backends.CloudBackend
end
```

---

## Pattern 5: SSE with Auto-Reconnection

### Purpose

Maintain SSE connections with automatic reconnection on failure.

### Implementation

```elixir
defmodule Lumainus.Conversion.Infrastructure.SSEStream do
  @moduledoc """
  SSE stream consumer with automatic reconnection.
  """

  use GenServer
  require Logger

  alias Lumainus.Conversion.Infrastructure.{ConnectionPool, Telemetry}

  @reconnect_delays [1_000, 2_000, 5_000, 10_000, 30_000]  # Escalating delays
  @heartbeat_timeout_ms 60_000  # Expect heartbeat within 60s

  defstruct [
    :job_id,
    :backend,
    :url,
    :caller,
    :reconnect_count,
    :last_event_at,
    :buffer
  ]

  # Public API

  @doc "Start streaming job status updates"
  def start_stream(job_id, backend, url, caller) do
    GenServer.start_link(__MODULE__, %{
      job_id: job_id,
      backend: backend,
      url: url,
      caller: caller
    })
  end

  @doc "Stop streaming"
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  # GenServer Implementation

  @impl true
  def init(args) do
    state = %__MODULE__{
      job_id: args.job_id,
      backend: args.backend,
      url: args.url,
      caller: args.caller,
      reconnect_count: 0,
      last_event_at: System.monotonic_time(:millisecond),
      buffer: ""
    }

    # Start connection
    send(self(), :connect)

    # Schedule heartbeat check
    schedule_heartbeat_check()

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case start_sse_connection(state) do
      :ok ->
        Telemetry.sse_connected(state.job_id, state.backend)
        {:noreply, %{state | reconnect_count: 0}}

      {:error, reason} ->
        handle_connection_error(state, reason)
    end
  end

  @impl true
  def handle_info({:sse_data, data}, state) do
    new_buffer = state.buffer <> data
    {events, remaining} = parse_sse_events(new_buffer)

    Enum.each(events, fn event ->
      send(state.caller, {:sse_event, state.job_id, event})

      if terminal_event?(event) do
        send(state.caller, {:sse_done, state.job_id, event["state"]})
      end
    end)

    {:noreply, %{state |
      buffer: remaining,
      last_event_at: System.monotonic_time(:millisecond)
    }}
  end

  @impl true
  def handle_info(:heartbeat_check, state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_event_at

    if elapsed > @heartbeat_timeout_ms do
      Logger.warning("SSE heartbeat timeout for job #{state.job_id}, reconnecting")
      Telemetry.sse_heartbeat_timeout(state.job_id)
      send(self(), :reconnect)
    end

    schedule_heartbeat_check()
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    delay = reconnect_delay(state.reconnect_count)
    Logger.info("SSE reconnecting for job #{state.job_id} in #{delay}ms (attempt #{state.reconnect_count + 1})")

    Process.sleep(delay)

    new_state = %{state | reconnect_count: state.reconnect_count + 1, buffer: ""}
    send(self(), :connect)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:sse_error, reason}, state) do
    Logger.warning("SSE error for job #{state.job_id}: #{inspect(reason)}")
    Telemetry.sse_error(state.job_id, reason)
    send(self(), :reconnect)
    {:noreply, state}
  end

  # Private

  defp start_sse_connection(state) do
    request = Finch.build(:get, state.url, [
      {"accept", "text/event-stream"},
      {"cache-control", "no-cache"}
    ])

    parent = self()

    Task.start(fn ->
      ConnectionPool.stream(state.backend, request, nil, fn
        {:status, status}, acc when status in 200..299 ->
          acc

        {:status, status}, _acc ->
          send(parent, {:sse_error, {:http_status, status}})
          :halt

        {:headers, _headers}, acc ->
          acc

        {:data, data}, acc ->
          send(parent, {:sse_data, data})
          acc
      end)
    end)

    :ok
  rescue
    e -> {:error, {:exception, e}}
  end

  defp handle_connection_error(state, reason) do
    if state.reconnect_count < length(@reconnect_delays) do
      send(self(), :reconnect)
      {:noreply, state}
    else
      send(state.caller, {:sse_error, state.job_id, :max_reconnects_exceeded})
      {:stop, :normal, state}
    end
  end

  defp reconnect_delay(count) do
    Enum.at(@reconnect_delays, min(count, length(@reconnect_delays) - 1))
  end

  defp schedule_heartbeat_check do
    Process.send_after(self(), :heartbeat_check, 15_000)
  end

  defp parse_sse_events(buffer) do
    case String.split(buffer, "\n\n", parts: 2) do
      [complete, rest] ->
        event = parse_sse_event(complete)
        {more_events, remaining} = parse_sse_events(rest)
        {[event | more_events], remaining}

      [incomplete] ->
        {[], incomplete}
    end
  end

  defp parse_sse_event(raw) do
    raw
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ": ", parts: 2) do
        ["data", value] ->
          case Jason.decode(value) do
            {:ok, data} -> Map.merge(acc, data)
            _ -> Map.put(acc, "raw_data", value)
          end

        ["event", value] ->
          Map.put(acc, "event_type", value)

        _ ->
          acc
      end
    end)
  end

  defp terminal_event?(%{"state" => state}) when state in ["completed", "failed", "cancelled"], do: true
  defp terminal_event?(_), do: false
end
```

---

## Pattern 6: Timeout Management

### Purpose

Intelligent timeout management based on context (file size, backend type, operation).

### Implementation

```elixir
defmodule Lumainus.Conversion.Infrastructure.TimeoutPolicy do
  @moduledoc """
  Dynamic timeout calculation based on context.
  """

  @base_timeout_ms 60_000  # 1 minute base
  @per_mb_timeout_ms 30_000  # 30 seconds per MB
  @max_timeout_ms 1_200_000  # 20 minutes max

  @backend_multipliers %{
    local_cpu: 2.0,
    local_docker_cpu: 2.0,
    local_gpu: 1.0,
    local_docker_gpu: 1.0,
    cloud: 1.0
  }

  @doc "Calculate timeout for conversion job"
  @spec timeout_for_job(map()) :: non_neg_integer()
  def timeout_for_job(%{byte_size: size, backend: backend}) do
    size_mb = size / (1024 * 1024)
    multiplier = Map.get(@backend_multipliers, backend, 1.5)

    timeout = @base_timeout_ms + (size_mb * @per_mb_timeout_ms * multiplier)
    min(round(timeout), @max_timeout_ms)
  end

  @doc "Calculate timeout for health check"
  @spec health_check_timeout(atom()) :: non_neg_integer()
  def health_check_timeout(:cloud), do: 30_000  # Cloud may need DNS resolution
  def health_check_timeout(_), do: 15_000

  @doc "Calculate timeout for status poll"
  @spec status_poll_timeout() :: non_neg_integer()
  def status_poll_timeout, do: 10_000

  @doc "Calculate poll interval"
  @spec poll_interval(non_neg_integer()) :: non_neg_integer()
  def poll_interval(elapsed_ms) do
    cond do
      elapsed_ms < 10_000 -> 500      # First 10s: poll every 500ms
      elapsed_ms < 60_000 -> 1_000    # 10s-1m: poll every 1s
      elapsed_ms < 300_000 -> 2_000   # 1-5m: poll every 2s
      true -> 5_000                    # 5m+: poll every 5s
    end
  end
end
```

---

## Resilience Configuration Summary

```elixir
# config/config.exs

config :lumainus, :conversion_circuit_breaker,
  threshold: 5,                  # Failures before opening
  timeout_ms: 30_000,           # Time in open state
  half_open_max_calls: 3        # Successful calls to close

config :lumainus, :conversion_retry,
  max_attempts: 3,
  base_delay_ms: 1_000,
  max_delay_ms: 30_000,
  jitter_factor: 0.2

config :lumainus, Lumainus.Conversion.ConnectionPool,
  pools: %{
    local: [size: 50, count: 4],
    cloud: [size: 25, count: 2]
  }

config :lumainus, :conversion_health,
  check_interval_ms: 30_000,
  unhealthy_threshold_ms: 90_000
```

---

## Next: Telemetry Strategy

See [03-telemetry.md](03-telemetry.md) for comprehensive observability implementation.
