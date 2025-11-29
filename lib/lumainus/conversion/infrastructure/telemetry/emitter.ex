defmodule Lumainus.Conversion.Infrastructure.Telemetry.Emitter do
  @moduledoc """
  Telemetry event emission for conversion operations.

  ## Cardinality Rules

  - Metrics use bounded tags only: profile, backend_type, error_type, status_bucket
  - NO tenant_id, job_id, or error strings in metrics
  - Job IDs go to logs and traces only
  - Progress telemetry is sampled (every 10%)

  ## Event Naming Convention

  All events are prefixed with `[:lumainus, :conversion, ...]`:

  - Job lifecycle: `[:lumainus, :conversion, :job, :submitted | :completed | :failed | :cancelled | :progress]`
  - Circuit breaker: `[:lumainus, :conversion, :circuit, :opened | :closed | :rejected]`
  - Retry: `[:lumainus, :conversion, :retry, :scheduled | :exhausted]`
  - Health: `[:lumainus, :conversion, :health, :checked | :unhealthy]`
  - SSE: `[:lumainus, :conversion, :sse, :connected | :reconnecting | :error | :heartbeat_timeout]`
  - HTTP: `[:lumainus, :conversion, :http, :request]`
  """

  @progress_sample_rate 10

  # ============================================================================
  # Job Lifecycle Events
  # ============================================================================

  @doc "Emit when a job is submitted."
  def emit_job_submitted(job) do
    :telemetry.execute(
      [:lumainus, :conversion, :job, :submitted],
      %{count: 1},
      %{profile: job.profile, backend_type: backend_type(job.backend_used)}
    )
  end

  @doc "Emit when a job completes successfully."
  def emit_job_completed(job) do
    duration = DateTime.diff(DateTime.utc_now(), job.submitted_at, :millisecond)

    :telemetry.execute(
      [:lumainus, :conversion, :job, :completed],
      %{count: 1, duration_ms: duration},
      %{profile: job.profile, backend_type: backend_type(job.backend_used)}
    )
  end

  @doc "Emit when a job fails."
  def emit_job_failed(job, error_type) do
    :telemetry.execute(
      [:lumainus, :conversion, :job, :failed],
      %{count: 1},
      %{
        profile: job.profile,
        backend_type: backend_type(job.backend_used),
        error_type: normalize_error_type(error_type)
      }
    )
  end

  @doc "Emit when a job is cancelled."
  def emit_job_cancelled(job) do
    :telemetry.execute(
      [:lumainus, :conversion, :job, :cancelled],
      %{count: 1},
      %{profile: job.profile, backend_type: backend_type(job.backend_used)}
    )
  end

  @doc "Emit job progress (sampled at 10% intervals)."
  def emit_job_progress(job, progress) do
    # Sample: only emit every 10% (use trunc for float progress)
    if rem(trunc(progress), @progress_sample_rate) == 0 do
      :telemetry.execute(
        [:lumainus, :conversion, :job, :progress],
        %{progress: progress},
        %{profile: job.profile, backend_type: backend_type(job.backend_used)}
      )
    end
  end

  # ============================================================================
  # Circuit Breaker Events
  # ============================================================================

  @doc "Emit when circuit breaker opens."
  def emit_circuit_opened(backend_name) do
    :telemetry.execute(
      [:lumainus, :conversion, :circuit, :opened],
      %{count: 1},
      %{backend: backend_name}
    )
  end

  @doc "Emit when circuit breaker closes."
  def emit_circuit_closed(backend_name) do
    :telemetry.execute(
      [:lumainus, :conversion, :circuit, :closed],
      %{count: 1},
      %{backend: backend_name}
    )
  end

  @doc "Emit when request rejected due to open circuit."
  def emit_circuit_rejected(backend_name) do
    :telemetry.execute(
      [:lumainus, :conversion, :circuit, :rejected],
      %{count: 1},
      %{backend: backend_name}
    )
  end

  # ============================================================================
  # Retry Events
  # ============================================================================

  @doc "Emit when a retry is scheduled."
  def emit_retry_scheduled(attempt, delay_ms, _reason) do
    :telemetry.execute(
      [:lumainus, :conversion, :retry, :scheduled],
      %{count: 1, delay_ms: delay_ms},
      %{attempt: attempt}
    )
  end

  @doc "Emit when retries are exhausted."
  def emit_retry_exhausted(attempts, _error) do
    :telemetry.execute(
      [:lumainus, :conversion, :retry, :exhausted],
      %{count: 1},
      %{attempts: attempts}
    )
  end

  # ============================================================================
  # Health Events
  # ============================================================================

  @doc "Emit successful health check."
  def emit_health_checked(backend_name, latency_ms) do
    :telemetry.execute(
      [:lumainus, :conversion, :health, :checked],
      %{latency_ms: latency_ms},
      %{backend: backend_name}
    )
  end

  @doc "Emit failed health check."
  def emit_health_unhealthy(backend_name) do
    :telemetry.execute(
      [:lumainus, :conversion, :health, :unhealthy],
      %{count: 1},
      %{backend: backend_name}
    )
  end

  # ============================================================================
  # SSE Events
  # ============================================================================

  @doc "Emit SSE connection established."
  def emit_sse_connected(_job_id) do
    :telemetry.execute(
      [:lumainus, :conversion, :sse, :connected],
      %{count: 1},
      %{}
    )
  end

  @doc "Emit SSE reconnection attempt."
  def emit_sse_reconnecting(_job_id, delay_ms) do
    :telemetry.execute(
      [:lumainus, :conversion, :sse, :reconnecting],
      %{count: 1, delay_ms: delay_ms},
      %{}
    )
  end

  @doc "Emit SSE error."
  def emit_sse_error(_job_id, _reason) do
    :telemetry.execute(
      [:lumainus, :conversion, :sse, :error],
      %{count: 1},
      %{}
    )
  end

  @doc "Emit SSE heartbeat timeout."
  def emit_sse_heartbeat_timeout(_job_id) do
    :telemetry.execute(
      [:lumainus, :conversion, :sse, :heartbeat_timeout],
      %{count: 1},
      %{}
    )
  end

  # ============================================================================
  # HTTP Events
  # ============================================================================

  @doc "Emit HTTP request completion."
  def emit_http_request(method, status, duration_ms, backend_type) do
    :telemetry.execute(
      [:lumainus, :conversion, :http, :request],
      %{duration_ms: duration_ms},
      %{
        method: method,
        status_bucket: status_bucket(status),
        backend_type: backend_type
      }
    )
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp backend_type(:local_cpu), do: :local
  defp backend_type(:local_gpu), do: :local
  defp backend_type(:docker_cpu), do: :local
  defp backend_type(:docker_gpu), do: :local
  defp backend_type(:cloud), do: :cloud
  defp backend_type(_), do: :unknown

  defp status_bucket(status) when status in 200..299, do: "2xx"
  defp status_bucket(status) when status in 400..499, do: "4xx"
  defp status_bucket(status) when status in 500..599, do: "5xx"
  defp status_bucket(_), do: "other"

  defp normalize_error_type(:timeout), do: :timeout
  defp normalize_error_type(:docling_failed), do: :docling_failed
  defp normalize_error_type({:transport_error, _}), do: :transport_error
  defp normalize_error_type({:http_error, status, _}) when status >= 500, do: :server_error
  defp normalize_error_type(_), do: :unknown
end
