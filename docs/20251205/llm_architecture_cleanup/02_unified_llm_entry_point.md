# 02: Unified LLM Entry Point

## Problem

Two completely different code paths for LLM calls:

```elixir
# section_run_worker.ex:32-35
if stream? do
  SectionRunner.run_section_streaming(...)  # Different behavior
else
  SectionRunner.run_section(...)            # Different behavior
end
```

These paths have different:
- Rate limiting behavior (streaming bypasses it)
- Error handling patterns
- Response processing
- Telemetry emission

The `stream?` flag silently determines system behavior with no indication to the caller.

## Current Architecture

```
SectionRunWorker.perform/1
    |
    +-- stream? = true --> run_section_streaming()
    |                          |
    |                          +-- invoke_llm_streaming()
    |                                   |
    |                                   +-- AI.client().stream_generate()
    |                                            |
    |                                            +-- LLM.stream_generate()
    |                                                     |
    |                                                     +-- Gemini.Streaming.UnifiedManager
    |                                                              |
    |                                                              +-- NO RATE LIMITER
    |
    +-- stream? = false --> run_section()
                               |
                               +-- invoke_llm()
                                        |
                                        +-- AI.client().generate_object()
                                                 |
                                                 +-- LLM.generate_object()
                                                          |
                                                          +-- Gemini.generate()
                                                                   |
                                                                   +-- RateLimiter.execute()
```

## Proposed Solution

### Single Entry Point with Mode Parameter

```elixir
# lib/lumainus/ai/section_runner.ex

@doc """
Run a section through the LLM.

Options:
  - `:mode` - `:streaming` or `:batch` (default: `:batch`)

Both modes go through the same rate limiting and error handling.
Streaming mode sends incremental updates via PubSub.
"""
def run_section(scope, section_run, patient, documents, opts \\ []) do
  mode = Keyword.get(opts, :mode, :batch)

  with {:ok, context} <- prepare_context(scope, section_run, patient, documents),
       {:ok, result} <- execute_with_rate_limit(context, mode, opts) do
    finalize_section(section_run, result)
  end
end

defp execute_with_rate_limit(context, mode, opts) do
  # Both modes go through the same gate
  Lumainus.AI.RateLimitedExecutor.execute(
    context.model_spec,
    fn -> do_execute(context, mode, opts) end,
    opts
  )
end

defp do_execute(context, :streaming, opts) do
  # Streaming implementation
  AI.client().stream_generate(...)
end

defp do_execute(context, :batch, _opts) do
  # Batch implementation
  AI.client().generate_object(...)
end
```

### New Rate Limited Executor Module

```elixir
# lib/lumainus/ai/rate_limited_executor.ex

defmodule Lumainus.AI.RateLimitedExecutor do
  @moduledoc """
  Application-level rate limiting wrapper for LLM calls.

  Provides a consistent gate regardless of streaming vs batch mode.
  Works in conjunction with gemini_ex rate limiter.
  """

  alias Lumainus.AI.Telemetry

  def execute(model_spec, fun, opts \\ []) do
    start_time = System.monotonic_time()

    Telemetry.emit_start(model_spec, opts)

    result =
      case acquire_permit(model_spec, opts) do
        :ok ->
          try do
            fun.()
          after
            release_permit(model_spec)
          end

        {:rate_limited, retry_after} ->
          Telemetry.emit_rate_limited(model_spec, retry_after)
          {:error, {:rate_limited, retry_after}}
      end

    Telemetry.emit_complete(model_spec, result, start_time)
    result
  end

  # Initially just pass-through to gemini_ex
  # Can add local semaphore later if needed
  defp acquire_permit(_model_spec, _opts), do: :ok
  defp release_permit(_model_spec), do: :ok
end
```

## Benefits

1. **Single code path** - Easier to reason about, test, maintain
2. **Consistent rate limiting** - Both modes go through same gate
3. **Unified telemetry** - Same events regardless of mode
4. **Explicit mode selection** - No silent behavioral differences

## Migration

### Phase 1: Add New Module

1. Create `Lumainus.AI.RateLimitedExecutor`
2. Create unified `run_section/5` that accepts mode option
3. Keep old functions as deprecated wrappers

### Phase 2: Update Callers

1. Update `SectionRunWorker` to use new API
2. Update `Reports.run_sections/6` to pass mode in job args
3. Remove `stream?` flag, use `:mode` option

### Phase 3: Remove Old Code

1. Remove `run_section_streaming/5`
2. Remove dual-path logic in worker
3. Update tests

## Files to Modify

- `lib/lumainus/ai/section_runner.ex` - Unified entry point
- `lib/lumainus/ai/rate_limited_executor.ex` - New module
- `lib/lumainus/reports/section_run_worker.ex` - Use new API
- `lib/lumainus/reports.ex` - Pass mode in job args

## Testing

1. Run sections in streaming mode - verify rate limited
2. Run sections in batch mode - verify rate limited
3. Mix streaming and batch - verify total concurrency controlled
4. Error in streaming - verify permit released
