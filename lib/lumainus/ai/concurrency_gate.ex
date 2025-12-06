defmodule Lumainus.AI.ConcurrencyGate do
  @moduledoc """
  Application-level concurrency control for LLM operations.

  Provides a local gate independent of gemini_ex rate limiter.
  Defense in depth for:
  - Streaming requests that may bypass gemini_ex
  - Cross-model concurrency limits
  - Circuit breaker functionality
  """

  use GenServer

  require Logger

  @default_max_concurrent 5
  @default_max_queue 50
  @default_timeout_ms 60_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquire a permit for an LLM operation.

  Returns:
  - `:ok` - Permit acquired
  - `{:queued, position}` - Waiting in queue (blocking mode)
  - `{:rejected, :queue_full}` - Too many waiting
  """
  def acquire(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    try do
      GenServer.call(__MODULE__, {:acquire, opts}, timeout)
    catch
      :exit, {:timeout, _} ->
        {:rejected, :timeout}
    end
  end

  @doc """
  Release a permit after operation completes.
  """
  def release do
    GenServer.cast(__MODULE__, {:release, self()})
  end

  @doc """
  Execute a function with automatic permit management.
  """
  def with_permit(fun, opts \\ []) do
    case acquire(opts) do
      :ok ->
        try do
          fun.()
        after
          release()
        end

      {:queued, _position} ->
        # Wait for grant
        receive do
          {:permit_granted, _ref} ->
            try do
              fun.()
            after
              release()
            end
        after
          Keyword.get(opts, :timeout, @default_timeout_ms) ->
            {:error, {:gate_timeout, :waiting}}
        end

      {:rejected, reason} ->
        {:error, {:gate_rejected, reason}}
    end
  end

  @doc """
  Check current gate status without acquiring.
  Uses short timeout to avoid blocking on overloaded gate.
  """
  def status do
    GenServer.call(__MODULE__, :status, 1_000)
  catch
    :exit, {:timeout, _} ->
      %{
        current: 0,
        max: 0,
        available: 0,
        queue_length: 0,
        max_queue: 0,
        metrics: %{},
        error: :timeout
      }
  end

  @doc """
  Check if the gate is available (non-blocking).
  Uses short timeout to avoid blocking on overloaded gate.
  """
  def available? do
    case GenServer.call(__MODULE__, :check_available, 1_000) do
      :available -> true
      _ -> false
    end
  catch
    :exit, {:timeout, _} -> false
  end

  # GenServer implementation

  @impl true
  def init(opts) do
    max_concurrent = Keyword.get(opts, :max_concurrent, @default_max_concurrent)
    max_queue = Keyword.get(opts, :max_queue, @default_max_queue)

    state = %{
      max_concurrent: max_concurrent,
      max_queue: max_queue,
      current: 0,
      holders: %{},
      waiting: :queue.new(),
      metrics: %{
        total_acquired: 0,
        total_rejected: 0,
        total_timeouts: 0,
        max_concurrent_seen: 0,
        max_queue_seen: 0
      }
    }

    Logger.info("AI ConcurrencyGate started: max=#{max_concurrent}, max_queue=#{max_queue}")

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, _opts}, {from_pid, _}, state) do
    cond do
      state.current < state.max_concurrent ->
        # Permit available
        ref = Process.monitor(from_pid)

        new_state = %{
          state
          | current: state.current + 1,
            holders: Map.put(state.holders, from_pid, ref),
            metrics:
              state.metrics
              |> Map.update!(:total_acquired, &(&1 + 1))
              |> Map.update(:max_concurrent_seen, state.current + 1, &max(&1, state.current + 1))
        }

        {:reply, :ok, new_state}

      :queue.len(state.waiting) < state.max_queue ->
        # Queue the request
        ref = Process.monitor(from_pid)
        new_waiting = :queue.in({from_pid, ref}, state.waiting)
        queue_len = :queue.len(new_waiting)

        new_metrics =
          Map.update(state.metrics, :max_queue_seen, queue_len, &max(&1, queue_len))

        {:reply, {:queued, queue_len}, %{state | waiting: new_waiting, metrics: new_metrics}}

      true ->
        # Reject
        new_metrics = Map.update!(state.metrics, :total_rejected, &(&1 + 1))
        {:reply, {:rejected, :queue_full}, %{state | metrics: new_metrics}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      current: state.current,
      max: state.max_concurrent,
      available: state.max_concurrent - state.current,
      queue_length: :queue.len(state.waiting),
      max_queue: state.max_queue,
      metrics: state.metrics
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:check_available, _from, state) do
    if state.current < state.max_concurrent do
      {:reply, :available, state}
    else
      {:reply, {:full, :queue.len(state.waiting)}, state}
    end
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    case Map.pop(state.holders, pid) do
      {nil, _} ->
        # Not a holder, ignore
        {:noreply, state}

      {ref, remaining_holders} ->
        Process.demonitor(ref, [:flush])

        new_state = %{
          state
          | current: max(state.current - 1, 0),
            holders: remaining_holders
        }

        {:noreply, maybe_grant_waiting(new_state)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    # Check if it was a holder
    case Map.pop(state.holders, pid) do
      {^ref, remaining_holders} ->
        new_state = %{
          state
          | current: max(state.current - 1, 0),
            holders: remaining_holders
        }

        {:noreply, maybe_grant_waiting(new_state)}

      _ ->
        # Was a waiter, remove from queue
        new_waiting =
          :queue.filter(fn {p, r} -> not (p == pid and r == ref) end, state.waiting)

        {:noreply, %{state | waiting: new_waiting}}
    end
  end

  defp maybe_grant_waiting(state) do
    if state.current < state.max_concurrent do
      case :queue.out(state.waiting) do
        {{:value, {pid, ref}}, remaining} ->
          # Grant permit to next waiter
          new_holders = Map.put(state.holders, pid, ref)
          send(pid, {:permit_granted, ref})

          new_state = %{
            state
            | current: state.current + 1,
              holders: new_holders,
              waiting: remaining,
              metrics: Map.update!(state.metrics, :total_acquired, &(&1 + 1))
          }

          # Recursively grant if more capacity
          maybe_grant_waiting(new_state)

        {:empty, _} ->
          state
      end
    else
      state
    end
  end
end
