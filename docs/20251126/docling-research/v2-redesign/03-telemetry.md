# v2 Telemetry Strategy

**Date:** November 26, 2025

---

## Overview

The v2 architecture implements comprehensive observability using Elixir's `:telemetry` library, providing:

1. **Metrics** - Counters, gauges, histograms for dashboards
2. **Traces** - Distributed tracing with correlation IDs
3. **Events** - Structured events for debugging and alerts
4. **Logs** - Structured logging with context

---

## Telemetry Events

### Event Naming Convention

All events follow the pattern: `[:medlum, :conversion, <component>, <action>]`

### Event Catalog

#### Job Lifecycle Events

```elixir
# Job submitted
[:medlum, :conversion, :job, :submitted]
  measurements: %{byte_size: integer}
  metadata: %{job_id: string, profile: atom, tenant_id: string}

# Job started processing
[:medlum, :conversion, :job, :started]
  measurements: %{queue_time_ms: integer}
  metadata: %{job_id: string, backend: atom}

# Job progress update
[:medlum, :conversion, :job, :progress]
  measurements: %{progress: integer, pages_done: integer, pages_total: integer}
  metadata: %{job_id: string, backend: atom}

# Job completed
[:medlum, :conversion, :job, :completed]
  measurements: %{duration_ms: integer, pages_total: integer}
  metadata: %{job_id: string, backend: atom, profile: atom}

# Job failed
[:medlum, :conversion, :job, :failed]
  measurements: %{duration_ms: integer}
  metadata: %{job_id: string, backend: atom, error: string, error_type: atom}

# Job cancelled
[:medlum, :conversion, :job, :cancelled]
  measurements: %{duration_ms: integer}
  metadata: %{job_id: string, backend: atom, reason: atom}
```

#### HTTP Events

```elixir
# HTTP request start
[:medlum, :conversion, :http, :request_start]
  measurements: %{}
  metadata: %{method: atom, path: string, backend: atom}

# HTTP request complete
[:medlum, :conversion, :http, :request_complete]
  measurements: %{duration_ms: integer, response_size: integer}
  metadata: %{method: atom, path: string, backend: atom, status: integer}

# HTTP request error
[:medlum, :conversion, :http, :request_error]
  measurements: %{duration_ms: integer}
  metadata: %{method: atom, path: string, backend: atom, error: term}
```

#### Circuit Breaker Events

```elixir
# Circuit opened
[:medlum, :conversion, :circuit, :opened]
  measurements: %{failure_count: integer}
  metadata: %{backend: atom}

# Circuit closed
[:medlum, :conversion, :circuit, :closed]
  measurements: %{}
  metadata: %{backend: atom}

# Circuit half-open
[:medlum, :conversion, :circuit, :half_open]
  measurements: %{}
  metadata: %{backend: atom}

# Request rejected by circuit
[:medlum, :conversion, :circuit, :rejected]
  measurements: %{}
  metadata: %{backend: atom}
```

#### Retry Events

```elixir
# Retry scheduled
[:medlum, :conversion, :retry, :scheduled]
  measurements: %{attempt: integer, delay_ms: integer}
  metadata: %{backend: atom, error: term}

# Retry succeeded
[:medlum, :conversion, :retry, :succeeded]
  measurements: %{attempt: integer}
  metadata: %{backend: atom}

# Retry exhausted
[:medlum, :conversion, :retry, :exhausted]
  measurements: %{attempt: integer}
  metadata: %{backend: atom, error: term}
```

#### Health Events

```elixir
# Health check performed
[:medlum, :conversion, :health, :checked]
  measurements: %{latency_ms: integer}
  metadata: %{backend: atom, status: atom}

# Backend became unhealthy
[:medlum, :conversion, :health, :unhealthy]
  measurements: %{}
  metadata: %{backend: atom, error: term}

# Backend recovered
[:medlum, :conversion, :health, :recovered]
  measurements: %{downtime_ms: integer}
  metadata: %{backend: atom}
```

#### SSE Events

```elixir
# SSE connected
[:medlum, :conversion, :sse, :connected]
  measurements: %{}
  metadata: %{job_id: string, backend: atom}

# SSE reconnected
[:medlum, :conversion, :sse, :reconnected]
  measurements: %{reconnect_count: integer}
  metadata: %{job_id: string, backend: atom}

# SSE error
[:medlum, :conversion, :sse, :error]
  measurements: %{}
  metadata: %{job_id: string, backend: atom, error: term}

# SSE heartbeat timeout
[:medlum, :conversion, :sse, :heartbeat_timeout]
  measurements: %{elapsed_ms: integer}
  metadata: %{job_id: string, backend: atom}
```

---

## Telemetry Emitter Module

```elixir
defmodule Medlum.Conversion.Infrastructure.Telemetry do
  @moduledoc """
  Centralized telemetry event emission for conversion system.
  """

  # Job Events

  def job_submitted(job) do
    :telemetry.execute(
      [:medlum, :conversion, :job, :submitted],
      %{byte_size: job.byte_size},
      %{
        job_id: job.id,
        profile: job.profile,
        tenant_id: job.tenant_id,
        filename: job.filename
      }
    )
  end

  def job_started(job, backend, queue_time_ms) do
    :telemetry.execute(
      [:medlum, :conversion, :job, :started],
      %{queue_time_ms: queue_time_ms},
      %{job_id: job.id, backend: backend}
    )
  end

  def job_progress(job_id, backend, progress, pages_done, pages_total) do
    :telemetry.execute(
      [:medlum, :conversion, :job, :progress],
      %{progress: progress, pages_done: pages_done, pages_total: pages_total},
      %{job_id: job_id, backend: backend}
    )
  end

  def job_completed(job, backend, duration_ms, pages_total) do
    :telemetry.execute(
      [:medlum, :conversion, :job, :completed],
      %{duration_ms: duration_ms, pages_total: pages_total},
      %{job_id: job.id, backend: backend, profile: job.profile}
    )
  end

  def job_failed(job, backend, duration_ms, error) do
    :telemetry.execute(
      [:medlum, :conversion, :job, :failed],
      %{duration_ms: duration_ms},
      %{
        job_id: job.id,
        backend: backend,
        error: inspect(error),
        error_type: classify_error(error)
      }
    )
  end

  # HTTP Events

  def http_request_start(method, path, backend) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:medlum, :conversion, :http, :request_start],
      %{},
      %{method: method, path: path, backend: backend, start_time: start_time}
    )

    start_time
  end

  def http_request_complete(method, path, backend, status, response_size, start_time) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:medlum, :conversion, :http, :request_complete],
      %{
        duration_ms: System.convert_time_unit(duration, :native, :millisecond),
        response_size: response_size
      },
      %{method: method, path: path, backend: backend, status: status}
    )
  end

  def http_request_error(method, path, backend, error, start_time) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:medlum, :conversion, :http, :request_error],
      %{duration_ms: System.convert_time_unit(duration, :native, :millisecond)},
      %{method: method, path: path, backend: backend, error: inspect(error)}
    )
  end

  # Circuit Breaker Events

  def circuit_opened(backend, failure_count) do
    :telemetry.execute(
      [:medlum, :conversion, :circuit, :opened],
      %{failure_count: failure_count},
      %{backend: backend}
    )
  end

  def circuit_closed(backend) do
    :telemetry.execute(
      [:medlum, :conversion, :circuit, :closed],
      %{},
      %{backend: backend}
    )
  end

  def circuit_half_open(backend) do
    :telemetry.execute(
      [:medlum, :conversion, :circuit, :half_open],
      %{},
      %{backend: backend}
    )
  end

  def circuit_rejected(backend) do
    :telemetry.execute(
      [:medlum, :conversion, :circuit, :rejected],
      %{},
      %{backend: backend}
    )
  end

  # Health Events

  def health_recorded(backend, status, details) do
    :telemetry.execute(
      [:medlum, :conversion, :health, :checked],
      %{latency_ms: details[:latency_ms] || 0},
      %{backend: backend, status: status}
    )
  end

  # Retry Events

  def retry_scheduled(attempt, delay_ms, error) do
    :telemetry.execute(
      [:medlum, :conversion, :retry, :scheduled],
      %{attempt: attempt, delay_ms: delay_ms},
      %{error: inspect(error)}
    )
  end

  def retry_succeeded(attempt) do
    :telemetry.execute(
      [:medlum, :conversion, :retry, :succeeded],
      %{attempt: attempt},
      %{}
    )
  end

  def retry_exhausted(attempt, error) do
    :telemetry.execute(
      [:medlum, :conversion, :retry, :exhausted],
      %{attempt: attempt},
      %{error: inspect(error)}
    )
  end

  # SSE Events

  def sse_connected(job_id, backend) do
    :telemetry.execute(
      [:medlum, :conversion, :sse, :connected],
      %{},
      %{job_id: job_id, backend: backend}
    )
  end

  def sse_error(job_id, error) do
    :telemetry.execute(
      [:medlum, :conversion, :sse, :error],
      %{},
      %{job_id: job_id, error: inspect(error)}
    )
  end

  def sse_heartbeat_timeout(job_id) do
    :telemetry.execute(
      [:medlum, :conversion, :sse, :heartbeat_timeout],
      %{},
      %{job_id: job_id}
    )
  end

  # Private

  defp classify_error({:http_error, status, _}) when status >= 500, do: :server_error
  defp classify_error({:http_error, 429, _}), do: :rate_limited
  defp classify_error({:http_error, _, _}), do: :client_error
  defp classify_error(:timeout), do: :timeout
  defp classify_error(:econnrefused), do: :connection_refused
  defp classify_error(:circuit_open), do: :circuit_open
  defp classify_error(_), do: :unknown
end
```

---

## Metrics Definitions

```elixir
defmodule Medlum.Conversion.Infrastructure.Metrics do
  @moduledoc """
  Telemetry metrics definitions for Prometheus export.
  """

  import Telemetry.Metrics

  def metrics do
    [
      # Job metrics
      counter("medlum.conversion.job.submitted.count",
        tags: [:profile, :tenant_id]
      ),
      counter("medlum.conversion.job.completed.count",
        tags: [:profile, :backend]
      ),
      counter("medlum.conversion.job.failed.count",
        tags: [:profile, :backend, :error_type]
      ),

      distribution("medlum.conversion.job.duration_ms",
        event_name: [:medlum, :conversion, :job, :completed],
        measurement: :duration_ms,
        tags: [:profile, :backend],
        reporter_options: [buckets: [1000, 5000, 10000, 30000, 60000, 120000, 300000, 600000]]
      ),

      distribution("medlum.conversion.job.queue_time_ms",
        event_name: [:medlum, :conversion, :job, :started],
        measurement: :queue_time_ms,
        tags: [:backend],
        reporter_options: [buckets: [100, 500, 1000, 5000, 10000, 30000]]
      ),

      last_value("medlum.conversion.job.byte_size",
        event_name: [:medlum, :conversion, :job, :submitted],
        measurement: :byte_size,
        tags: [:profile]
      ),

      # HTTP metrics
      distribution("medlum.conversion.http.duration_ms",
        event_name: [:medlum, :conversion, :http, :request_complete],
        measurement: :duration_ms,
        tags: [:backend, :method, :status],
        reporter_options: [buckets: [10, 50, 100, 500, 1000, 5000, 10000]]
      ),

      counter("medlum.conversion.http.errors.count",
        event_name: [:medlum, :conversion, :http, :request_error],
        tags: [:backend, :method]
      ),

      # Circuit breaker metrics
      counter("medlum.conversion.circuit.opened.count",
        tags: [:backend]
      ),
      counter("medlum.conversion.circuit.rejected.count",
        tags: [:backend]
      ),

      # Retry metrics
      counter("medlum.conversion.retry.count",
        event_name: [:medlum, :conversion, :retry, :scheduled],
        tags: []
      ),
      counter("medlum.conversion.retry.exhausted.count",
        tags: []
      ),

      # Health metrics
      last_value("medlum.conversion.health.latency_ms",
        event_name: [:medlum, :conversion, :health, :checked],
        measurement: :latency_ms,
        tags: [:backend, :status]
      ),

      # SSE metrics
      counter("medlum.conversion.sse.errors.count",
        tags: [:backend]
      ),
      counter("medlum.conversion.sse.reconnects.count",
        tags: [:backend]
      )
    ]
  end
end
```

---

## Distributed Tracing

### Span Creation

```elixir
defmodule Medlum.Conversion.Infrastructure.Span do
  @moduledoc """
  Distributed tracing spans for conversion operations.
  """

  @doc "Create a span for job processing"
  def with_span(name, metadata, fun) do
    trace_id = get_or_create_trace_id(metadata)
    span_id = generate_span_id()
    parent_span_id = metadata[:span_id]

    start_time = System.monotonic_time()

    try do
      result = fun.()
      complete_span(name, trace_id, span_id, parent_span_id, start_time, :ok, metadata)
      result
    rescue
      e ->
        complete_span(name, trace_id, span_id, parent_span_id, start_time, :error, Map.put(metadata, :error, e))
        reraise e, __STACKTRACE__
    end
  end

  @doc "Get trace context for propagation"
  def trace_context(metadata) do
    %{
      trace_id: metadata[:trace_id] || generate_trace_id(),
      span_id: metadata[:span_id] || generate_span_id()
    }
  end

  defp get_or_create_trace_id(%{trace_id: id}) when is_binary(id), do: id
  defp get_or_create_trace_id(_), do: generate_trace_id()

  defp generate_trace_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp generate_span_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp complete_span(name, trace_id, span_id, parent_span_id, start_time, status, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:medlum, :conversion, :span, :complete],
      %{
        duration_ms: System.convert_time_unit(duration, :native, :millisecond)
      },
      %{
        name: name,
        trace_id: trace_id,
        span_id: span_id,
        parent_span_id: parent_span_id,
        status: status,
        metadata: metadata
      }
    )
  end
end
```

### Correlation ID Propagation

```elixir
defmodule Medlum.Conversion.Infrastructure.Context do
  @moduledoc """
  Request context with correlation ID for tracing.
  """

  @context_key :conversion_context

  defstruct [
    :correlation_id,
    :trace_id,
    :span_id,
    :tenant_id,
    :user_id,
    :job_id
  ]

  @doc "Set context for current process"
  def put(context) do
    Process.put(@context_key, context)
  end

  @doc "Get context for current process"
  def get do
    Process.get(@context_key, %__MODULE__{})
  end

  @doc "Create new context with correlation ID"
  def new(attrs \\ %{}) do
    %__MODULE__{
      correlation_id: attrs[:correlation_id] || generate_correlation_id(),
      trace_id: attrs[:trace_id] || generate_trace_id(),
      span_id: attrs[:span_id],
      tenant_id: attrs[:tenant_id],
      user_id: attrs[:user_id],
      job_id: attrs[:job_id]
    }
  end

  @doc "Create child context (new span)"
  def child(parent \\ get()) do
    %__MODULE__{parent |
      span_id: generate_span_id()
    }
  end

  defp generate_correlation_id, do: Ecto.UUID.generate()
  defp generate_trace_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp generate_span_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
```

---

## Structured Logging

```elixir
defmodule Medlum.Conversion.Infrastructure.StructuredLogger do
  @moduledoc """
  Structured logging with automatic context injection.
  """

  require Logger
  alias Medlum.Conversion.Infrastructure.Context

  @doc "Log with context"
  def log(level, message, extra \\ %{}) do
    context = Context.get()

    metadata = %{
      correlation_id: context.correlation_id,
      trace_id: context.trace_id,
      span_id: context.span_id,
      tenant_id: context.tenant_id,
      job_id: context.job_id
    }
    |> Map.merge(extra)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into([])

    Logger.log(level, message, metadata)
  end

  def debug(message, extra \\ %{}), do: log(:debug, message, extra)
  def info(message, extra \\ %{}), do: log(:info, message, extra)
  def warning(message, extra \\ %{}), do: log(:warning, message, extra)
  def error(message, extra \\ %{}), do: log(:error, message, extra)
end
```

---

## Telemetry Handlers

```elixir
defmodule Medlum.Conversion.Infrastructure.TelemetryHandler do
  @moduledoc """
  Attaches telemetry handlers for logging and alerting.
  """

  require Logger

  def attach do
    events = [
      [:medlum, :conversion, :job, :submitted],
      [:medlum, :conversion, :job, :completed],
      [:medlum, :conversion, :job, :failed],
      [:medlum, :conversion, :circuit, :opened],
      [:medlum, :conversion, :circuit, :rejected],
      [:medlum, :conversion, :health, :checked],
      [:medlum, :conversion, :retry, :exhausted]
    ]

    :telemetry.attach_many(
      "conversion-logger",
      events,
      &handle_event/4,
      nil
    )
  end

  def handle_event([:medlum, :conversion, :job, :submitted], measurements, metadata, _config) do
    Logger.info("Job submitted",
      job_id: metadata.job_id,
      profile: metadata.profile,
      byte_size: measurements.byte_size
    )
  end

  def handle_event([:medlum, :conversion, :job, :completed], measurements, metadata, _config) do
    Logger.info("Job completed",
      job_id: metadata.job_id,
      backend: metadata.backend,
      duration_ms: measurements.duration_ms,
      pages: measurements.pages_total
    )
  end

  def handle_event([:medlum, :conversion, :job, :failed], measurements, metadata, _config) do
    Logger.error("Job failed",
      job_id: metadata.job_id,
      backend: metadata.backend,
      error: metadata.error,
      error_type: metadata.error_type,
      duration_ms: measurements.duration_ms
    )
  end

  def handle_event([:medlum, :conversion, :circuit, :opened], measurements, metadata, _config) do
    Logger.warning("Circuit breaker opened",
      backend: metadata.backend,
      failure_count: measurements.failure_count
    )
  end

  def handle_event([:medlum, :conversion, :circuit, :rejected], _measurements, metadata, _config) do
    Logger.warning("Request rejected by circuit breaker",
      backend: metadata.backend
    )
  end

  def handle_event([:medlum, :conversion, :health, :checked], measurements, metadata, _config) do
    if metadata.status == :unhealthy do
      Logger.warning("Backend unhealthy",
        backend: metadata.backend,
        latency_ms: measurements.latency_ms
      )
    end
  end

  def handle_event([:medlum, :conversion, :retry, :exhausted], measurements, metadata, _config) do
    Logger.error("Retries exhausted",
      attempt: measurements.attempt,
      error: metadata.error
    )
  end
end
```

---

## Prometheus Configuration

```elixir
# config/config.exs

config :medlum, MedlumWeb.Telemetry,
  metrics: Medlum.Conversion.Infrastructure.Metrics.metrics()

# In application.ex
def start(_type, _args) do
  children = [
    # ... other children ...
    {TelemetryMetricsPrometheus, metrics: Medlum.Conversion.Infrastructure.Metrics.metrics()}
  ]
end
```

---

## Dashboard Queries (Grafana/Prometheus)

### Job Throughput

```promql
# Jobs per minute by profile
rate(medlum_conversion_job_completed_count[1m]) by (profile)

# Jobs per minute by backend
rate(medlum_conversion_job_completed_count[1m]) by (backend)
```

### Error Rate

```promql
# Error rate by backend
rate(medlum_conversion_job_failed_count[5m]) by (backend)
/
(rate(medlum_conversion_job_completed_count[5m]) by (backend)
+ rate(medlum_conversion_job_failed_count[5m]) by (backend))
```

### Latency Percentiles

```promql
# P95 conversion duration by profile
histogram_quantile(0.95, rate(medlum_conversion_job_duration_ms_bucket[5m])) by (profile)

# P99 HTTP latency by backend
histogram_quantile(0.99, rate(medlum_conversion_http_duration_ms_bucket[5m])) by (backend)
```

### Circuit Breaker Status

```promql
# Circuit breaker openings per hour
increase(medlum_conversion_circuit_opened_count[1h]) by (backend)

# Rejections due to open circuit
rate(medlum_conversion_circuit_rejected_count[5m]) by (backend)
```

### Health Status

```promql
# Backend health latency
medlum_conversion_health_latency_ms by (backend, status)
```

---

## Alert Rules

```yaml
# alerts.yml
groups:
  - name: conversion
    rules:
      - alert: HighConversionErrorRate
        expr: |
          rate(medlum_conversion_job_failed_count[5m])
          / (rate(medlum_conversion_job_completed_count[5m]) + rate(medlum_conversion_job_failed_count[5m]))
          > 0.1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High conversion error rate"
          description: "Error rate is {{ $value | humanizePercentage }}"

      - alert: CircuitBreakerOpen
        expr: increase(medlum_conversion_circuit_opened_count[5m]) > 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Circuit breaker opened for {{ $labels.backend }}"

      - alert: BackendUnhealthy
        expr: medlum_conversion_health_latency_ms{status="unhealthy"} > 0
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Backend {{ $labels.backend }} is unhealthy"

      - alert: HighConversionLatency
        expr: histogram_quantile(0.95, rate(medlum_conversion_job_duration_ms_bucket[5m])) > 600000
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "P95 conversion latency exceeds 10 minutes"
```

---

## Next: Testing Strategy

See [04-testing.md](04-testing.md) for comprehensive testing patterns.
