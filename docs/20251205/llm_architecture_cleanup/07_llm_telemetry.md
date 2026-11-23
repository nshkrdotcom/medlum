# 07: LLM Rate Limiting Telemetry

## Problem

When 429s or rate limiting occurs, there's no medlum-level telemetry:

- Can't observe rate limit events from application dashboards
- No metrics for rate limit frequency
- No visibility into queue depths or wait times
- Hard to diagnose performance issues

The conversion module has comprehensive telemetry (`Medlum.Conversion.Infrastructure.Telemetry.Emitter`), but LLM operations have none.

## Current State

```elixir
# Conversion has telemetry
:telemetry.execute([:medlum, :conversion, :start], ...)
:telemetry.execute([:medlum, :conversion, :complete], ...)

# LLM has nothing
AI.client().generate_object(...)  # No telemetry
AI.client().stream_generate(...)  # No telemetry
```

gemini_ex emits telemetry, but medlum doesn't attach handlers or emit its own.

## Proposed Solution

### LLM Telemetry Emitter

```elixir
# lib/medlum/ai/telemetry.ex

defmodule Medlum.AI.Telemetry do
  @moduledoc """
  Telemetry emission for LLM operations.

  ## Events

  ### [:medlum, :llm, :request, :start]
  Emitted when an LLM request begins.

  Measurements: `%{system_time: integer()}`
  Metadata: `%{model: string(), use_case: atom(), mode: :streaming | :batch}`

  ### [:medlum, :llm, :request, :stop]
  Emitted when an LLM request completes successfully.

  Measurements: `%{duration: integer(), input_tokens: integer(), output_tokens: integer()}`
  Metadata: `%{model: string(), use_case: atom(), mode: atom()}`

  ### [:medlum, :llm, :request, :exception]
  Emitted when an LLM request fails.

  Measurements: `%{duration: integer()}`
  Metadata: `%{model: string(), use_case: atom(), error_type: atom(), error: term()}`

  ### [:medlum, :llm, :rate_limit, :hit]
  Emitted when a request is rate limited.

  Measurements: `%{retry_after_ms: integer()}`
  Metadata: `%{model: string(), reason: atom(), quota_metric: string()}`

  ### [:medlum, :llm, :rate_limit, :wait]
  Emitted when a request waits for rate limit window.

  Measurements: `%{wait_ms: integer()}`
  Metadata: `%{model: string()}`

  ### [:medlum, :llm, :concurrency, :queued]
  Emitted when a request is queued for concurrency.

  Measurements: `%{queue_position: integer()}`
  Metadata: `%{model: string()}`

  ### [:medlum, :llm, :concurrency, :acquired]
  Emitted when a concurrency permit is acquired.

  Measurements: `%{wait_ms: integer()}`
  Metadata: `%{model: string(), current: integer(), max: integer()}`
  """

  @doc """
  Emit request start event.
  """
  def emit_start(model, use_case, mode) do
    :telemetry.execute(
      [:medlum, :llm, :request, :start],
      %{system_time: System.system_time()},
      %{model: model, use_case: use_case, mode: mode}
    )
  end

  @doc """
  Emit request completion event.
  """
  def emit_stop(model, use_case, mode, start_time, usage) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:medlum, :llm, :request, :stop],
      %{
        duration: duration,
        input_tokens: Map.get(usage, :input_tokens, 0),
        output_tokens: Map.get(usage, :output_tokens, 0),
        cached_tokens: Map.get(usage, :cached_tokens, 0)
      },
      %{model: model, use_case: use_case, mode: mode}
    )
  end

  @doc """
  Emit request exception event.
  """
  def emit_exception(model, use_case, start_time, error) do
    duration = System.monotonic_time() - start_time
    {error_type, _} = classify_error(error)

    :telemetry.execute(
      [:medlum, :llm, :request, :exception],
      %{duration: duration},
      %{model: model, use_case: use_case, error_type: error_type, error: error}
    )
  end

  @doc """
  Emit rate limit hit event.
  """
  def emit_rate_limit_hit(model, reason, retry_after_ms, details \\ %{}) do
    :telemetry.execute(
      [:medlum, :llm, :rate_limit, :hit],
      %{retry_after_ms: retry_after_ms || 0},
      Map.merge(%{model: model, reason: reason}, details)
    )
  end

  @doc """
  Emit rate limit wait event.
  """
  def emit_rate_limit_wait(model, wait_ms) do
    :telemetry.execute(
      [:medlum, :llm, :rate_limit, :wait],
      %{wait_ms: wait_ms},
      %{model: model}
    )
  end

  @doc """
  Emit concurrency queued event.
  """
  def emit_concurrency_queued(model, position) do
    :telemetry.execute(
      [:medlum, :llm, :concurrency, :queued],
      %{queue_position: position},
      %{model: model}
    )
  end

  @doc """
  Emit concurrency acquired event.
  """
  def emit_concurrency_acquired(model, wait_ms, current, max) do
    :telemetry.execute(
      [:medlum, :llm, :concurrency, :acquired],
      %{wait_ms: wait_ms},
      %{model: model, current: current, max: max}
    )
  end

  defp classify_error({:rate_limited, _, _}), do: {:rate_limited, true}
  defp classify_error(%{type: :rate_limited}), do: {:rate_limited, true}
  defp classify_error(%{type: :api_error}), do: {:api_error, false}
  defp classify_error(%{type: :network_error}), do: {:network_error, true}
  defp classify_error(_), do: {:unknown, false}
end
```

### Attach to gemini_ex Telemetry

```elixir
# lib/medlum/ai/telemetry_handler.ex

defmodule Medlum.AI.TelemetryHandler do
  @moduledoc """
  Attaches to gemini_ex telemetry events and re-emits as medlum events.
  """

  require Logger

  def attach do
    events = [
      [:gemini, :rate_limit, :request, :start],
      [:gemini, :rate_limit, :request, :stop],
      [:gemini, :rate_limit, :wait],
      [:gemini, :rate_limit, :error],
      [:gemini, :rate_limit, :budget, :reserved],
      [:gemini, :rate_limit, :budget, :rejected]
    ]

    :telemetry.attach_many(
      "medlum-gemini-handler",
      events,
      &handle_event/4,
      nil
    )
  end

  def handle_event([:gemini, :rate_limit, :wait], measurements, metadata, _config) do
    Logger.debug("Gemini rate limit wait: #{inspect(measurements)}")

    :telemetry.execute(
      [:medlum, :llm, :rate_limit, :wait],
      %{wait_ms: measurements[:wait_ms] || 0},
      %{model: metadata[:model], source: :gemini_ex}
    )
  end

  def handle_event([:gemini, :rate_limit, :error], _measurements, metadata, _config) do
    Logger.warning("Gemini rate limit error: #{inspect(metadata)}")

    :telemetry.execute(
      [:medlum, :llm, :rate_limit, :hit],
      %{retry_after_ms: 0},
      %{
        model: metadata[:model],
        reason: metadata[:reason],
        source: :gemini_ex
      }
    )
  end

  def handle_event([:gemini, :rate_limit, :budget, :rejected], _measurements, metadata, _config) do
    Logger.warning("Gemini budget rejected: #{inspect(metadata)}")

    :telemetry.execute(
      [:medlum, :llm, :rate_limit, :hit],
      %{retry_after_ms: 0},
      %{
        model: metadata[:model],
        reason: :over_budget,
        source: :gemini_ex
      }
    )
  end

  def handle_event(_event, _measurements, _metadata, _config) do
    :ok
  end
end
```

### Add Metrics to Phoenix Telemetry

```elixir
# lib/medlum_web/telemetry.ex

def metrics do
  [
    # Existing metrics...

    # LLM Metrics
    counter("medlum.llm.request.start.count",
      tags: [:model, :use_case, :mode]
    ),

    summary("medlum.llm.request.stop.duration",
      unit: {:native, :millisecond},
      tags: [:model, :use_case, :mode]
    ),

    sum("medlum.llm.request.stop.input_tokens",
      tags: [:model]
    ),

    sum("medlum.llm.request.stop.output_tokens",
      tags: [:model]
    ),

    counter("medlum.llm.request.exception.count",
      tags: [:model, :error_type]
    ),

    counter("medlum.llm.rate_limit.hit.count",
      tags: [:model, :reason]
    ),

    summary("medlum.llm.rate_limit.wait.wait_ms",
      unit: :millisecond,
      tags: [:model]
    ),

    last_value("medlum.llm.concurrency.acquired.current",
      tags: [:model]
    )
  ]
end
```

### Attach Handler on Application Start

```elixir
# lib/medlum/application.ex

def start(_type, _args) do
  # Attach telemetry handlers
  Medlum.AI.TelemetryHandler.attach()

  children = [
    # ...
  ]

  # ...
end
```

## Benefits

1. **Observability** - See rate limiting in dashboards
2. **Alerting** - Alert on high rate limit frequency
3. **Debugging** - Trace request timing and failures
4. **Capacity planning** - Track token usage over time
5. **Cost tracking** - Sum input/output tokens by model

## Files to Modify

- `lib/medlum/ai/telemetry.ex` - New emitter module
- `lib/medlum/ai/telemetry_handler.ex` - gemini_ex handler
- `lib/medlum/application.ex` - Attach handlers
- `lib/medlum_web/telemetry.ex` - Add metrics
- `lib/medlum/ai/section_runner.ex` - Emit events

## Testing

1. Request start emits event
2. Request stop emits with duration and tokens
3. Exception emits with error type
4. Rate limit from gemini_ex re-emitted
5. Metrics appear in LiveDashboard
