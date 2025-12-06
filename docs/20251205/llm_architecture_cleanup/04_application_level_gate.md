# 04: Application-Level Concurrency Gate

## Problem

Lumainus relies entirely on gemini_ex's rate limiter. When that fails (streaming bypass), there's no fallback:

- No circuit breaker
- No local semaphore
- No queue depth monitoring
- No backpressure signal to callers

## Current State

```
Reports.run_sections()
    |
    +-- Enqueue N Oban jobs (no limit check)
           |
           +-- Oban dispatches up to queue limit
                  |
                  +-- Each worker calls LLM
                         |
                         +-- gemini_ex rate limiter (only defense)
                                |
                                +-- (bypassed by streaming)
```

## Proposed Solution

### Application-Level Semaphore

```elixir
# lib/lumainus/ai/concurrency_gate.ex

defmodule Lumainus.AI.ConcurrencyGate do
  @moduledoc """
  Application-level concurrency control for LLM operations.

  Provides a local gate independent of gemini_ex rate limiter.
  Useful for:
  - Streaming requests that bypass gemini_ex
  - Cross-model concurrency limits
  - Circuit breaker functionality
  """

  use GenServer

  @default_max_concurrent 5
  @default_timeout_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquire a permit for an LLM operation.

  Returns:
  - `:ok` - Permit acquired
  - `{:queued, position}` - Waiting in queue
  - `{:rejected, :queue_full}` - Too many waiting
  """
  def acquire(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    GenServer.call(__MODULE__, :acquire, timeout)
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

      {:rejected, reason} ->
        {:error, {:gate_rejected, reason}}
    end
  end

  @doc """
  Check current gate status without acquiring.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # GenServer implementation

  @impl true
  def init(opts) do
    max_concurrent = Keyword.get(opts, :max_concurrent, @default_max_concurrent)
    max_queue = Keyword.get(opts, :max_queue, 100)

    state = %{
      max_concurrent: max_concurrent,
      max_queue: max_queue,
      current: 0,
      holders: %{},  # pid -> monitor_ref
      waiting: :queue.new(),
      metrics: %{
        total_acquired: 0,
        total_rejected: 0,
        total_timeouts: 0
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:acquire, {from_pid, _}, state) do
    cond do
      state.current < state.max_concurrent ->
        # Permit available
        ref = Process.monitor(from_pid)
        new_state = %{state |
          current: state.current + 1,
          holders: Map.put(state.holders, from_pid, ref),
          metrics: update_in(state.metrics.total_acquired, &(&1 + 1))
        }
        {:reply, :ok, new_state}

      :queue.len(state.waiting) < state.max_queue ->
        # Queue the request
        ref = Process.monitor(from_pid)
        new_waiting = :queue.in({from_pid, ref}, state.waiting)
        {:reply, {:queued, :queue.len(new_waiting)}, %{state | waiting: new_waiting}}

      true ->
        # Reject
        new_metrics = update_in(state.metrics.total_rejected, &(&1 + 1))
        {:reply, {:rejected, :queue_full}, %{state | metrics: new_metrics}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      current: state.current,
      max: state.max_concurrent,
      queue_length: :queue.len(state.waiting),
      max_queue: state.max_queue,
      metrics: state.metrics
    }
    {:reply, status, state}
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    case Map.pop(state.holders, pid) do
      {nil, _} ->
        # Not a holder, ignore
        {:noreply, state}

      {ref, remaining_holders} ->
        Process.demonitor(ref, [:flush])
        new_state = %{state |
          current: state.current - 1,
          holders: remaining_holders
        }
        {:noreply, maybe_grant_waiting(new_state)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    # Holder crashed, release their permit
    case Map.pop(state.holders, pid) do
      {^ref, remaining_holders} ->
        new_state = %{state |
          current: state.current - 1,
          holders: remaining_holders
        }
        {:noreply, maybe_grant_waiting(new_state)}

      _ ->
        # Was a waiter, remove from queue
        new_waiting = :queue.filter(fn {p, _} -> p != pid end, state.waiting)
        {:noreply, %{state | waiting: new_waiting}}
    end
  end

  defp maybe_grant_waiting(state) do
    case :queue.out(state.waiting) do
      {{:value, {pid, ref}}, remaining} when state.current < state.max_concurrent ->
        # Grant permit to next waiter
        new_holders = Map.put(state.holders, pid, ref)
        send(pid, {:permit_granted, ref})
        %{state |
          current: state.current + 1,
          holders: new_holders,
          waiting: remaining
        }

      _ ->
        state
    end
  end
end
```

### Integrate with SectionRunner

```elixir
# lib/lumainus/ai/section_runner.ex

defp invoke_llm_streaming(model_spec, prompt_text, schema, options, context) do
  ConcurrencyGate.with_permit(fn ->
    AI.client().stream_generate(model_spec, prompt_text, schema, self(), options)
  end)
end
```

### Add to Supervision Tree

```elixir
# lib/lumainus/application.ex

children = [
  # ... existing children
  {Lumainus.AI.ConcurrencyGate, max_concurrent: 5, max_queue: 50},
]
```

## Benefits

1. **Defense in depth** - Works even if gemini_ex rate limiter is bypassed
2. **Visibility** - `status/0` shows current state
3. **Backpressure** - Queue full rejection signals overload
4. **Crash safety** - Monitors holders, releases on crash
5. **Configurable** - Adjust limits without code changes

## Configuration

```elixir
# config/config.exs

config :lumainus, Lumainus.AI.ConcurrencyGate,
  max_concurrent: 5,
  max_queue: 50,
  timeout_ms: 60_000
```

## Files to Modify

- `lib/lumainus/ai/concurrency_gate.ex` - New module
- `lib/lumainus/application.ex` - Add to supervision
- `lib/lumainus/ai/section_runner.ex` - Use gate
- `config/config.exs` - Configuration

## Testing

1. Acquire max permits - verify next is queued
2. Release permit - verify waiter granted
3. Holder crashes - verify permit released
4. Queue full - verify rejection
5. Status check - verify accurate counts
