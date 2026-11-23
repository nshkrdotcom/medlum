# Conversion System v2 - Phoenix Integration Guide

## Overview

This document outlines how to fully integrate the Conversion System v2 into the Medlum Phoenix application. The v2 system provides a robust, resilient document conversion pipeline with:

- Config-driven backend routing
- Circuit breakers and health monitoring
- Real-time progress via PubSub events
- Provenance tracking for debugging

## Current Implementation Status

### Completed (217 tests passing)

| Module | Location | Purpose |
|--------|----------|---------|
| Job | `lib/medlum/conversion/job.ex` | Ecto schema for conversion jobs |
| JobStatus | `lib/medlum/conversion/job_status.ex` | Status struct with provenance |
| Policy | `lib/medlum/conversion/policy.ex` | Validation rules (size, type, access) |
| ProcessingProfile | `lib/medlum/conversion/processing_profile.ex` | :standard / :enhanced profiles |
| Context | `lib/medlum/conversion/infrastructure/context.ex` | Request tracing context |
| HTTP.Client | `lib/medlum/conversion/infrastructure/http/client.ex` | HTTP client for backends |
| HTTP.SSEStream | `lib/medlum/conversion/infrastructure/http/sse_stream.ex` | SSE progress streaming |
| CircuitBreaker | `lib/medlum/conversion/infrastructure/resilience/circuit_breaker.ex` | Per-backend circuit breaker |
| RetryPolicy | `lib/medlum/conversion/infrastructure/resilience/retry_policy.ex` | Exponential backoff retries |
| Telemetry.Emitter | `lib/medlum/conversion/infrastructure/telemetry/emitter.ex` | Metrics emission |
| HealthManager | `lib/medlum/conversion/infrastructure/health_manager.ex` | Backend health monitoring |
| BackendRouter | `lib/medlum/conversion/infrastructure/backend_router.ex` | Config-driven routing |
| LocalBackend | `lib/medlum/conversion/backends/local_backend.ex` | Docker/native backends |
| CloudBackend | `lib/medlum/conversion/backends/cloud_backend.ex` | Vast.ai cloud backend |
| JobTracker | `lib/medlum/conversion/application/job_tracker.ex` | ETS cache + DB persistence |
| Service | `lib/medlum/conversion/service.ex` | Public API |
| Events | `lib/medlum/conversion/events.ex` | PubSub broadcasting |
| Migration | `priv/repo/migrations/20251126200256_create_conversion_jobs.exs` | Database schema |

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Phoenix Application                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────────┐  │
│  │  LiveView    │    │  Controller  │    │  Existing Documents      │  │
│  │  (real-time) │    │  (REST API)  │    │  Module Integration      │  │
│  └──────┬───────┘    └──────┬───────┘    └────────────┬─────────────┘  │
│         │                   │                         │                 │
│         └───────────────────┴─────────────────────────┘                 │
│                             │                                           │
│                             ▼                                           │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                    Conversion.Service                             │  │
│  │  submit/2  status/2  await/3  cancel/2  available?/2  profiles/1 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│         │                   │                         │                 │
│         ▼                   ▼                         ▼                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────────────┐│
│  │ JobTracker  │    │   Events    │    │      BackendRouter          ││
│  │ (ETS + DB)  │    │  (PubSub)   │    │  (health + circuit + route) ││
│  └─────────────┘    └─────────────┘    └─────────────────────────────┘│
│                                                   │                     │
│                           ┌───────────────────────┴───────────────┐    │
│                           ▼                                       ▼    │
│                    ┌─────────────┐                        ┌───────────┐│
│                    │LocalBackend │                        │CloudBackend│
│                    └──────┬──────┘                        └─────┬─────┘│
└───────────────────────────┼─────────────────────────────────────┼──────┘
                            │                                     │
                            ▼                                     ▼
                   ┌─────────────────┐                  ┌─────────────────┐
                   │  Docker/Native  │                  │    Vast.ai      │
                   │  Docling (local)│                  │  GPU Instance   │
                   │  localhost:8042 │                  │  (provisioned)  │
                   └─────────────────┘                  └─────────────────┘
```

---

## Integration Steps

### Step 1: Run Database Migration

```bash
cd /path/to/medlum
mix ecto.migrate
```

This creates the `conversion_jobs` table with:
- Job metadata (profile, filename, size)
- Backend provenance (backend_used, backend_endpoint, instance_id)
- State tracking (state, progress, pages_done/total)
- Result storage (result map, last_error)

### Step 2: Configure Backends

Edit `config/config.exs` or `config/runtime.exs`:

```elixir
# Default configuration (already added)
config :medlum, :conversion,
  backends: [
    {:docker_cpu, endpoint: "http://localhost:8042", type: :local},
    {:docker_gpu, endpoint: "http://localhost:8043", type: :local},
    {:cloud, type: :cloud}
  ],
  profiles: %{
    standard: [:docker_cpu],
    enhanced: [:docker_gpu, :cloud]
  }
```

#### Configuration Modes

**Cloud-Only** (production without local GPU):
```elixir
config :medlum, :conversion,
  backends: [{:cloud, type: :cloud}],
  profiles: %{
    standard: [:cloud],
    enhanced: [:cloud]
  }
```

**Local-Only** (development):
```elixir
config :medlum, :conversion,
  backends: [{:docker_cpu, endpoint: "http://localhost:8042", type: :local}],
  profiles: %{
    standard: [:docker_cpu],
    enhanced: [:docker_cpu]
  }
```

### Step 3: Create REST API Controller

Create `lib/medlum_web/controllers/api/v2/conversion_controller.ex`:

```elixir
defmodule MedlumWeb.API.V2.ConversionController do
  use MedlumWeb, :controller

  alias Medlum.Conversion.Service
  alias Medlum.Conversion.Events

  action_fallback MedlumWeb.FallbackController

  @doc "POST /api/v2/conversions"
  def create(conn, %{"file" => upload} = params) do
    binary = File.read!(upload.path)

    opts = [
      filename: upload.filename,
      content_type: upload.content_type,
      profile: parse_profile(params["profile"]),
      user_id: conn.assigns[:current_user]&.id,
      tenant_id: conn.assigns[:current_scope]&.tenant_id
    ]

    case Service.submit(binary, opts) do
      {:ok, job} ->
        conn
        |> put_status(:accepted)
        |> json(%{
          job_id: job.id,
          status: "queued",
          profile: job.profile
        })

      {:error, :file_too_large} ->
        conn |> put_status(:request_entity_too_large) |> json(%{error: "file_too_large"})

      {:error, :invalid_content_type} ->
        conn |> put_status(:unsupported_media_type) |> json(%{error: "invalid_content_type"})

      {:error, :service_unavailable} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "no_backends_available"})
    end
  end

  @doc "GET /api/v2/conversions/:id"
  def show(conn, %{"id" => job_id}) do
    case Service.status(job_id) do
      {:ok, status} ->
        json(conn, %{
          job_id: status.job_id,
          state: status.state,
          progress: status.progress,
          pages_done: status.pages_done,
          pages_total: status.pages_total,
          backend_used: status.backend_used,
          result: status.result,
          error: status.error
        })

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  @doc "DELETE /api/v2/conversions/:id"
  def delete(conn, %{"id" => job_id}) do
    case Service.cancel(job_id) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  @doc "GET /api/v2/conversions/:id/events (SSE stream)"
  def events(conn, %{"id" => job_id}) do
    Events.subscribe(job_id)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    stream_events(conn, job_id)
  end

  defp stream_events(conn, job_id) do
    receive do
      {:conversion_job, :progress, %{progress: p}} ->
        {:ok, conn} = chunk(conn, "event: progress\ndata: #{Jason.encode!(%{progress: p})}\n\n")
        stream_events(conn, job_id)

      {:conversion_job, :completed, job} ->
        chunk(conn, "event: completed\ndata: #{Jason.encode!(%{result: job.result})}\n\n")
        conn

      {:conversion_job, :failed, %{reason: reason}} ->
        chunk(conn, "event: failed\ndata: #{Jason.encode!(%{error: inspect(reason)})}\n\n")
        conn

      {:conversion_job, :cancelled, _} ->
        chunk(conn, "event: cancelled\ndata: {}\n\n")
        conn
    after
      30_000 ->
        {:ok, conn} = chunk(conn, ": heartbeat\n\n")
        stream_events(conn, job_id)
    end
  end

  defp parse_profile("enhanced"), do: :enhanced
  defp parse_profile(_), do: :standard
end
```

Add routes in `lib/medlum_web/router.ex`:

```elixir
scope "/api/v2", MedlumWeb.API.V2 do
  pipe_through :api

  resources "/conversions", ConversionController, only: [:create, :show, :delete]
  get "/conversions/:id/events", ConversionController, :events
end
```

### Step 4: LiveView Integration

Subscribe to job events in LiveView for real-time updates:

```elixir
defmodule MedlumWeb.ConversionLive do
  use MedlumWeb, :live_view

  alias Medlum.Conversion.{Service, Events}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, jobs: [], uploading: false)}
  end

  def handle_event("upload", %{"file" => file}, socket) do
    binary = File.read!(file.path)

    case Service.submit(binary, filename: file.filename, profile: :standard) do
      {:ok, job} ->
        # Subscribe to this job's events
        Events.subscribe(job.id)

        {:noreply,
         socket
         |> update(:jobs, &[job | &1])
         |> put_flash(:info, "Conversion started")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  # Handle real-time progress updates
  def handle_info({:conversion_job, :progress, %{job_id: id, progress: p}}, socket) do
    jobs = update_job_progress(socket.assigns.jobs, id, p)
    {:noreply, assign(socket, jobs: jobs)}
  end

  def handle_info({:conversion_job, :completed, job}, socket) do
    jobs = update_job_state(socket.assigns.jobs, job.id, :completed, job.result)
    {:noreply, assign(socket, jobs: jobs)}
  end

  def handle_info({:conversion_job, :failed, %{job_id: id, reason: reason}}, socket) do
    jobs = update_job_state(socket.assigns.jobs, id, :failed, nil)
    {:noreply,
     socket
     |> assign(jobs: jobs)
     |> put_flash(:error, "Conversion failed: #{inspect(reason)}")}
  end

  defp update_job_progress(jobs, id, progress) do
    Enum.map(jobs, fn job ->
      if job.id == id, do: %{job | progress: progress}, else: job
    end)
  end

  defp update_job_state(jobs, id, state, result) do
    Enum.map(jobs, fn job ->
      if job.id == id, do: %{job | state: state, result: result}, else: job
    end)
  end
end
```

### Step 5: Integrate with Existing Documents Module

The existing `Medlum.Documents` module can call the v2 Service:

```elixir
# In lib/medlum/documents.ex

defmodule Medlum.Documents do
  alias Medlum.Conversion.Service, as: ConversionV2

  @doc """
  Start conversion using v2 system.
  """
  def convert_document_v2(document, opts \\ []) do
    binary = fetch_document_binary(document)

    conversion_opts = [
      filename: document.filename,
      content_type: document.content_type,
      profile: Keyword.get(opts, :profile, :standard),
      user_id: document.user_id,
      tenant_id: document.tenant_id,
      metadata: %{document_id: document.id}
    ]

    case ConversionV2.submit(binary, conversion_opts) do
      {:ok, job} ->
        # Link conversion job to document
        update_document(document, %{conversion_job_id: job.id})
        {:ok, job}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Await conversion completion with progress callback.
  """
  def await_conversion(job_id, opts \\ []) do
    ConversionV2.await(job_id, opts)
  end
end
```

### Step 6: Add Telemetry Handlers (Optional)

Create `lib/medlum_web/telemetry.ex` handlers for metrics:

```elixir
# In existing telemetry.ex, add:

defp conversion_metrics do
  [
    # Job lifecycle
    counter("medlum.conversion.job.submitted.count"),
    counter("medlum.conversion.job.completed.count"),
    counter("medlum.conversion.job.failed.count"),

    # Durations
    distribution("medlum.conversion.job.completed.duration_ms",
      unit: :millisecond,
      reporter_options: [buckets: [100, 500, 1000, 5000, 10000, 30000, 60000]]
    ),

    # Circuit breaker
    counter("medlum.conversion.circuit.opened.count"),
    counter("medlum.conversion.circuit.rejected.count"),

    # Health
    distribution("medlum.conversion.health.checked.latency_ms")
  ]
end
```

---

## API Reference

### Service.submit/2

```elixir
Service.submit(binary, opts)

# Options:
#   :filename (required) - Original filename
#   :profile - :standard (default) or :enhanced
#   :content_type - MIME type (default: "application/pdf")
#   :user_id - Submitting user ID
#   :tenant_id - Organization ID
#   :timeout_ms - Custom timeout (capped at profile max)
#   :metadata - Additional metadata map

# Returns:
#   {:ok, Job.t()} - Job submitted successfully
#   {:error, :file_too_large} - File exceeds 100MB
#   {:error, :invalid_content_type} - Not a PDF
#   {:error, :service_unavailable} - No backends available
```

### Service.status/2

```elixir
Service.status(job_id, opts \\ [])

# Returns:
#   {:ok, JobStatus.t()} - Current status with provenance
#   {:error, :not_found} - Job doesn't exist
```

### Service.await/3

```elixir
Service.await(job_id, opts \\ [])

# Options:
#   :timeout_ms - Override timeout
#   :on_progress - fn(JobStatus.t()) -> :ok end

# Returns:
#   {:ok, result_map} - Conversion result
#   {:error, :timeout} - Job timed out
#   {:error, {:failed, reason}} - Conversion failed
```

### Service.cancel/2

```elixir
Service.cancel(job_id, opts \\ [])

# Returns:
#   :ok - Cancelled
#   {:error, :not_found}
```

### Events.subscribe/1

```elixir
Events.subscribe(job_id)

# Subscribes calling process to receive:
#   {:conversion_job, :submitted, job}
#   {:conversion_job, :progress, %{job_id: id, progress: 0..100}}
#   {:conversion_job, :completed, job}
#   {:conversion_job, :failed, %{job_id: id, reason: term}}
#   {:conversion_job, :cancelled, job}
```

---

## Testing

Run all conversion tests:

```bash
mix test test/medlum/conversion/
# 217 tests, 0 failures
```

Run specific module tests:

```bash
mix test test/medlum/conversion/service_test.exs
mix test test/medlum/conversion/infrastructure/backend_router_test.exs
```

---

## Monitoring & Debugging

### Check Backend Health

```elixir
iex> Medlum.Conversion.Infrastructure.HealthManager.status(:docker_cpu)
:healthy

iex> Medlum.Conversion.Infrastructure.HealthManager.latency(:docker_cpu)
45  # milliseconds
```

### Check Circuit Breaker State

```elixir
iex> Medlum.Conversion.Infrastructure.Resilience.CircuitBreaker.state(:docker_cpu)
:closed
```

### Route a Profile

```elixir
iex> Medlum.Conversion.Infrastructure.BackendRouter.route(:standard)
{:ok, %{name: :docker_cpu, endpoint: "http://localhost:8042", ...}}
```

### Get Job Status

```elixir
iex> Medlum.Conversion.Service.status("job-uuid-here")
{:ok, %Medlum.Conversion.JobStatus{
  job_id: "...",
  state: :processing,
  progress: 45,
  backend_used: :docker_cpu,
  backend_endpoint: "http://localhost:8042"
}}
```

---

## Migration from v1

The v2 system can run alongside the existing v1 Docling system. Gradual migration:

1. **Phase 1**: Deploy v2, route new features to v2
2. **Phase 2**: Add feature flag to switch existing flows
3. **Phase 3**: Migrate all flows, deprecate v1
4. **Phase 4**: Remove v1 code

The `Documents` module can call either system based on a feature flag:

```elixir
def convert_document(document, opts) do
  if feature_enabled?(:conversion_v2, document.tenant_id) do
    convert_document_v2(document, opts)
  else
    convert_document_v1(document, opts)
  end
end
```

---

## Critical Design Rules

1. **NO RETRIES ON ENQUEUE** - `Service.submit/2` does not retry the backend enqueue call because it's not idempotent.

2. **Error Classification** - Only 5xx, 429, and transport errors trip circuit breakers. 4xx errors are client errors and don't indicate backend health issues.

3. **Provenance Tracking** - Every job stores `backend_used`, `backend_endpoint`, and `instance_id` for debugging production issues.

4. **Health Staleness** - Health data older than 90 seconds returns `:unknown` status, giving benefit of the doubt to backends.

5. **Progress Sampling** - Telemetry emits progress at 10% intervals to avoid metric cardinality explosion.
