defmodule Lumainus.Conversion.Infrastructure.Resilience.CircuitBreaker do
  @moduledoc """
  Per-backend circuit breaker using GenServer.

  ## States

  - `:closed` — Normal operation, requests pass through
  - `:open` — Failing, reject immediately
  - `:half_open` — Testing recovery, allow ONE probe

  ## Error Classification

  Failures that trip the breaker:
  - HTTP 5xx errors
  - HTTP 429 (rate limited)
  - Transport errors (connection refused, timeout)
  - Request timeouts

  NOT counted as failures:
  - HTTP 4xx (except 429) — client errors
  - Validation errors
  - Successful responses

  ## Configuration

  - `failure_threshold` — Number of failures to trip breaker (default: 5)
  - `open_timeout_ms` — Time before half-open attempt (default: 30_000)
  - `half_open_max_probes` — Concurrent probes in half-open (always: 1)

  ## Usage

      # Start a circuit breaker
      {:ok, pid} = CircuitBreaker.start_link(backend_name: :docker_cpu)

      # Check state
      :closed = CircuitBreaker.state(pid)

      # Execute through breaker
      {:ok, result} = CircuitBreaker.call(pid, fn -> make_request() end)

      # Record outcomes
      CircuitBreaker.record_success(pid)
      CircuitBreaker.record_failure(pid, {:http_error, 500, %{}})
  """

  use GenServer
  require Logger

  @default_failure_threshold 5
  @default_open_timeout_ms 30_000
  @half_open_max_probes 1

  @type state :: :closed | :open | :half_open

  defstruct [
    :backend_name,
    state: :closed,
    failure_count: 0,
    last_failure_at: nil,
    open_until: nil,
    half_open_probes: 0,
    failure_threshold: @default_failure_threshold,
    open_timeout_ms: @default_open_timeout_ms
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start a circuit breaker for a backend.

  ## Options

  - `:backend_name` — Required. Name of the backend
  - `:failure_threshold` — Failures to trip (default: 5)
  - `:open_timeout_ms` — Time before half-open (default: 30_000)
  - `:name` — Optional. Explicit name (for testing). If not provided,
    uses Registry-based naming.
  """
  def start_link(opts) do
    backend_name = Keyword.fetch!(opts, :backend_name)

    gen_server_opts =
      case Keyword.get(opts, :name, :via_registry) do
        :via_registry ->
          # Use Registry-based naming (requires Registry to be started)
          [name: via(backend_name)]

        nil ->
          # No name registration (useful for testing)
          []

        explicit_name ->
          # Explicit name
          [name: explicit_name]
      end

    GenServer.start_link(__MODULE__, opts, gen_server_opts)
  end

  @doc """
  Get current breaker state.

  Returns `:closed` if no breaker exists for the backend.
  """
  @spec state(pid() | atom()) :: state()
  def state(pid_or_name) when is_pid(pid_or_name) do
    GenServer.call(pid_or_name, :state)
  end

  def state(backend_name) when is_atom(backend_name) do
    case whereis_safe(backend_name) do
      nil -> :closed
      pid -> GenServer.call(pid, :state)
    end
  end

  @doc """
  Execute function through breaker.

  Returns `{:error, :circuit_open}` if breaker is open.
  """
  @spec call(pid() | atom(), (-> result)) :: result | {:error, :circuit_open} when result: term()
  def call(pid, fun) when is_pid(pid) do
    GenServer.call(pid, {:call, fun})
  end

  def call(backend_name, fun) when is_atom(backend_name) do
    case whereis_safe(backend_name) do
      nil -> fun.()
      pid -> GenServer.call(pid, {:call, fun})
    end
  end

  @doc """
  Record a successful call.
  """
  @spec record_success(pid() | atom()) :: :ok
  def record_success(pid) when is_pid(pid) do
    GenServer.cast(pid, :success)
  end

  def record_success(backend_name) when is_atom(backend_name) do
    case whereis_safe(backend_name) do
      nil -> :ok
      pid -> GenServer.cast(pid, :success)
    end
  end

  @doc """
  Record a failure (only if it should count).
  """
  @spec record_failure(pid() | atom(), term()) :: :ok
  def record_failure(pid, error) when is_pid(pid) do
    if should_count_as_failure?(error) do
      GenServer.cast(pid, {:failure, error})
    end

    :ok
  end

  def record_failure(backend_name, error) when is_atom(backend_name) do
    if should_count_as_failure?(error) do
      case whereis_safe(backend_name) do
        nil -> :ok
        pid -> GenServer.cast(pid, {:failure, error})
      end
    end

    :ok
  end

  @doc """
  Classify errors for breaker counting.

  Returns `true` for errors that should trip the breaker:
  - HTTP 5xx errors
  - HTTP 429 (rate limited)
  - Transport errors
  - Timeouts

  Returns `false` for:
  - HTTP 4xx (except 429)
  - Other errors
  """
  @spec should_count_as_failure?(term()) :: boolean()
  def should_count_as_failure?({:http_error, status, _}) when status >= 500, do: true
  def should_count_as_failure?({:http_error, 429, _}), do: true
  def should_count_as_failure?({:http_error, _, _}), do: false
  def should_count_as_failure?({:transport_error, _}), do: true
  def should_count_as_failure?(:timeout), do: true
  def should_count_as_failure?(%Req.TransportError{}), do: true
  def should_count_as_failure?(_), do: false

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    backend_name = Keyword.fetch!(opts, :backend_name)

    state = %__MODULE__{
      backend_name: backend_name,
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      open_timeout_ms: Keyword.get(opts, :open_timeout_ms, @default_open_timeout_ms)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state) do
    current = evaluate_state(state)
    {:reply, current, state}
  end

  @impl true
  def handle_call({:call, fun}, _from, state) do
    case evaluate_state(state) do
      :open ->
        {:reply, {:error, :circuit_open}, state}

      :half_open when state.half_open_probes >= @half_open_max_probes ->
        {:reply, {:error, :circuit_open}, state}

      :half_open ->
        new_state = %{state | half_open_probes: state.half_open_probes + 1}
        result = execute_and_record(fun, self())
        {:reply, result, new_state}

      :closed ->
        result = fun.()
        {:reply, result, state}
    end
  end

  @impl true
  def handle_cast(:success, state) do
    new_state =
      case evaluate_state(state) do
        :half_open ->
          Logger.info("[CircuitBreaker] #{state.backend_name} recovered, closing circuit")

          %{
            state
            | state: :closed,
              failure_count: 0,
              half_open_probes: 0,
              open_until: nil
          }

        _ ->
          %{state | failure_count: 0}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:failure, _error}, state) do
    new_count = state.failure_count + 1
    now = System.monotonic_time(:millisecond)

    new_state =
      cond do
        evaluate_state(state) == :half_open ->
          Logger.warning("[CircuitBreaker] #{state.backend_name} probe failed, reopening")

          %{
            state
            | state: :open,
              failure_count: new_count,
              last_failure_at: now,
              open_until: now + state.open_timeout_ms,
              half_open_probes: 0
          }

        new_count >= state.failure_threshold ->
          Logger.warning(
            "[CircuitBreaker] #{state.backend_name} threshold reached (#{new_count}), opening"
          )

          %{
            state
            | state: :open,
              failure_count: new_count,
              last_failure_at: now,
              open_until: now + state.open_timeout_ms
          }

        true ->
          %{state | failure_count: new_count, last_failure_at: now}
      end

    {:noreply, new_state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp via(backend_name) do
    {:via, Registry, {Lumainus.Conversion.Registry, {:circuit_breaker, backend_name}}}
  end

  # Safe lookup that handles missing Registry
  defp whereis_safe(backend_name) do
    GenServer.whereis(via(backend_name))
  rescue
    ArgumentError -> nil
  end

  defp evaluate_state(%{state: :open, open_until: open_until}) do
    now = System.monotonic_time(:millisecond)

    if now >= open_until do
      :half_open
    else
      :open
    end
  end

  defp evaluate_state(%{state: state}), do: state

  defp execute_and_record(fun, pid) do
    result = fun.()

    # Record success if result is {:ok, _}
    case result do
      {:ok, _} -> GenServer.cast(pid, :success)
      {:error, reason} -> GenServer.cast(pid, {:failure, reason})
      _ -> :ok
    end

    result
  end
end
