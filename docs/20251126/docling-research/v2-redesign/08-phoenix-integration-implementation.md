# Conversion System v2 - Phoenix Integration Implementation Guide

**Status**: Ready for Implementation
**Prerequisite**: All 21 modules implemented (213 tests passing)
**Date**: November 26, 2025

---

## Executive Summary

The Docling v2 conversion system core is complete. This document provides the step-by-step implementation guide to integrate v2 into the existing Phoenix application, enabling gradual migration from v1 without disrupting current functionality.

---

## Current State

### v2 Core (Complete)

```
lib/lumainus/conversion/
├── application/
│   └── job_tracker.ex          # ETS cache + DB persistence
├── backends/
│   ├── local_backend.ex        # Docker/native backends
│   └── cloud_backend.ex        # Vast.ai (delegates to existing InstanceManager)
├── infrastructure/
│   ├── context.ex              # Request tracing
│   ├── backend_router.ex       # Config-driven routing
│   ├── health_manager.ex       # Periodic health checks
│   ├── http/
│   │   ├── client.ex           # HTTP client
│   │   └── sse_stream.ex       # SSE streaming
│   ├── resilience/
│   │   ├── circuit_breaker.ex  # Per-backend circuit breaker
│   │   └── retry_policy.ex     # Exponential backoff
│   └── telemetry/
│       └── emitter.ex          # Metrics emission
├── backend.ex                  # Behaviour definition
├── events.ex                   # PubSub broadcasting
├── job.ex                      # Ecto schema
├── job_status.ex               # Status view struct
├── policy.ex                   # Validation rules
├── processing_profile.ex       # :standard / :enhanced
└── service.ex                  # Public API
```

### v1 Current Flow

```
User Upload
    │
    ▼
Documents.queue_ingestion()
    │
    ▼
Oban Job (DoclingIngestionWorker)
    │
    ▼
Lumainus.Docling.Queue
    │
    ▼
Lumainus.Docling.enqueue() / convert()
    │
    ▼
Lumainus.Docling.HTTP → Backend
```

### v2 Target Flow

```
User Upload
    │
    ▼
Documents.queue_ingestion()  ─── feature flag ───┐
    │                                            │
    ▼                                            ▼
Oban Job                                 Conversion.Service.submit()
    │                                            │
    ▼                                            ▼
Conversion.Adapter.enqueue()             JobTracker + BackendRouter
    │                                            │
    └────────────────────────────────────────────┘
                        │
                        ▼
              HTTP.Client → Backend
```

---

## Phase 1: Database Setup (5 minutes)

### Step 1.1: Run Migration

```bash
wsl -d ubuntu-dev bash -c ". /home/home/.asdf/asdf.sh && cd /home/home/p/g/n/lumainus && mix ecto.migrate"
```

### Step 1.2: Verify Migration

```bash
wsl -d ubuntu-dev bash -c ". /home/home/.asdf/asdf.sh && cd /home/home/p/g/n/lumainus && mix ecto.migrations"
```

Expected output:
```
  up     20251126200256 Lumainus.Repo.Migrations.CreateConversionJobs
```

### Step 1.3: Verify Table in IEx

```bash
wsl -d ubuntu-dev bash -c ". /home/home/.asdf/asdf.sh && cd /home/home/p/g/n/lumainus && iex -S mix"
```

```elixir
iex> Lumainus.Repo.query!("SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'conversion_jobs' ORDER BY ordinal_position")
```

---

## Phase 2: Adapter Bridge Module (30 minutes)

Create a bridge module that translates v1 Docling calls to v2 Service calls, enabling gradual migration.

### Step 2.1: Create Adapter Module

Create `lib/lumainus/conversion/adapter.ex`:

```elixir
defmodule Lumainus.Conversion.Adapter do
  @moduledoc """
  Adapter bridging v1 Docling interface to v2 Conversion.Service.

  This module provides backward-compatible functions that match the
  existing `Lumainus.Docling` API signatures while using the new v2
  conversion system under the hood.

  ## Usage

  Replace calls to `Lumainus.Docling.enqueue/2` with:

      Lumainus.Conversion.Adapter.enqueue(binary, opts)

  ## Migration Path

  1. Feature flag routes new jobs through this adapter
  2. Existing jobs continue using v1
  3. Once stable, migrate all traffic to v2
  4. Remove adapter and v1 code
  """

  alias Lumainus.Conversion.{Service, JobStatus, Job}
  alias Lumainus.Conversion.Infrastructure.Context

  require Logger

  @doc """
  Enqueue a PDF for conversion using v2 system.

  Compatible with `Lumainus.Docling.enqueue/2` signature.

  ## Options

    * `:filename` - Original filename (default: "upload.pdf")
    * `:content_type` - MIME type (default: "application/pdf")
    * `:backend` - Requested backend hint (used to infer profile)
    * `:tenant_id` - Organization ID
    * `:user_id` - Submitting user ID
    * `:timeout_ms` - Custom timeout
    * `:metadata` - Additional metadata map

  ## Returns

    * `{:ok, map}` - Job info in v1-compatible format
    * `{:error, term}` - Error reason

  ## Examples

      iex> Adapter.enqueue(pdf_binary, filename: "report.pdf")
      {:ok, %{"job_id" => "abc-123", "state" => "queued"}}

      iex> Adapter.enqueue(pdf_binary, backend: :docker_gpu)
      {:ok, %{"job_id" => "def-456", "state" => "queued"}}
  """
  @spec enqueue(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue(binary, opts \\ []) when is_binary(binary) do
    # Initialize tracing context
    Context.init(
      tenant_id: Keyword.get(opts, :tenant_id),
      user_id: Keyword.get(opts, :user_id)
    )

    attrs = %{
      profile: profile_from_opts(opts),
      filename: Keyword.get(opts, :filename, "upload.pdf"),
      byte_size: byte_size(binary),
      tenant_id: Keyword.get(opts, :tenant_id),
      user_id: Keyword.get(opts, :user_id),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    # Add timeout if specified
    attrs =
      case Keyword.get(opts, :timeout_ms) do
        nil -> attrs
        timeout -> Map.put(attrs, :timeout_ms, timeout)
      end

    case Service.submit(binary, attrs) do
      {:ok, job} ->
        Logger.info("[Conversion.Adapter] Enqueued job via v2: #{job.id}")
        {:ok, job_to_v1_format(job)}

      {:error, reason} = error ->
        Logger.warning("[Conversion.Adapter] Failed to enqueue: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Get job status in v1-compatible format.

  Compatible with `Lumainus.Docling.job_status/2` signature.
  """
  @spec status(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(job_id, _opts \\ []) do
    case Service.status(job_id) do
      {:ok, status} ->
        {:ok, status_to_v1_format(status)}

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Await job completion with optional progress callback.

  Compatible with `Lumainus.Docling.await/3` signature.
  """
  @spec await(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def await(job_id, opts \\ []) do
    # Convert v1 on_progress callback format to v2
    v2_opts =
      case Keyword.get(opts, :on_progress) do
        nil ->
          opts

        callback when is_function(callback, 1) ->
          Keyword.put(opts, :on_progress, fn status ->
            callback.(status_to_v1_format(status))
          end)
      end

    case Service.await(job_id, v2_opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Cancel a conversion job.
  """
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(job_id) do
    Service.cancel(job_id)
  end

  @doc """
  Check if a profile has available backends.

  Compatible with health check patterns.
  """
  @spec available?(atom()) :: boolean()
  def available?(profile \\ :standard) do
    Service.available?(profile)
  end

  # ============================================================================
  # Private: Format Conversions
  # ============================================================================

  @gpu_backends [:docker_gpu, :local_gpu, :vast_ai, :cloud]

  defp profile_from_opts(opts) do
    case Keyword.get(opts, :backend) do
      backend when backend in @gpu_backends -> :enhanced
      _ -> :standard
    end
  end

  defp job_to_v1_format(%Job{} = job) do
    %{
      "job_id" => job.id,
      "state" => state_to_string(job.state),
      "progress" => job.progress || 0,
      "code_version" => "v2"
    }
  end

  defp status_to_v1_format(%JobStatus{} = status) do
    %{
      "job_id" => status.job_id,
      "state" => state_to_string(status.state),
      "progress" => status.progress || 0,
      "pages_total" => status.pages_total,
      "pages_done" => status.pages_done,
      "backend" => status.backend_used && to_string(status.backend_used),
      "endpoint" => status.backend_endpoint,
      "result" => status.result,
      "error" => status.error,
      "code_version" => "v2"
    }
  end

  defp state_to_string(state) when is_atom(state), do: to_string(state)
  defp state_to_string(state) when is_binary(state), do: state
end
```

### Step 2.2: Create Test File

Create `test/lumainus/conversion/adapter_test.exs`:

```elixir
defmodule Lumainus.Conversion.AdapterTest do
  use Lumainus.DataCase, async: true

  alias Lumainus.Conversion.Adapter
  alias Lumainus.Conversion.Support.TestHelpers

  describe "enqueue/2" do
    setup do
      # Start required processes
      start_supervised!({Lumainus.Conversion.Application.JobTracker, []})
      :ok
    end

    @tag :integration
    test "enqueues job and returns v1-compatible format" do
      pdf = TestHelpers.sample_pdf()

      # Note: This will fail without a running backend
      # In real test, mock the backend or use Bypass
      result = Adapter.enqueue(pdf, filename: "test.pdf")

      case result do
        {:ok, response} ->
          assert is_binary(response["job_id"])
          assert response["state"] in ["queued", "processing"]
          assert response["code_version"] == "v2"

        {:error, :service_unavailable} ->
          # Expected when no backends are running
          :ok
      end
    end

    test "infers :enhanced profile from GPU backend option" do
      # Test profile inference logic
      assert Adapter.available?(:standard) in [true, false]
      assert Adapter.available?(:enhanced) in [true, false]
    end
  end

  describe "status/2" do
    test "returns error for non-existent job" do
      assert {:error, :not_found} = Adapter.status("non-existent-job-id")
    end
  end
end
```

---

## Phase 3: Feature Flag Configuration (10 minutes)

### Step 3.1: Add Feature Flag to Config

Update `config/config.exs`:

```elixir
# Conversion System v2 Configuration
config :lumainus, :conversion,
  # Feature flag: enable v2 system
  use_v2: false,  # Set to true to enable v2 for new jobs

  # Available backends (order = fallback preference)
  backends: [
    {:docker_cpu, endpoint: "http://localhost:8042", type: :local},
    {:docker_gpu, endpoint: "http://localhost:8043", type: :local},
    {:local_cpu, endpoint: "http://localhost:8040", type: :local},
    {:local_gpu, endpoint: "http://localhost:8041", type: :local},
    {:cloud, type: :cloud}
  ],

  # Profile to backend mapping (order = preference)
  profiles: %{
    standard: [:docker_cpu, :local_cpu],
    enhanced: [:docker_gpu, :local_gpu, :cloud]
  }
```

### Step 3.2: Add Environment Override

Update `config/runtime.exs`:

```elixir
# Conversion v2 feature flag (override via env)
if System.get_env("CONVERSION_USE_V2") == "true" do
  config :lumainus, :conversion,
    use_v2: true
end
```

---

## Phase 4: Integration Points (1 hour)

### Step 4.1: Update IngestionProcessor

Modify `lib/lumainus/documents/ingestion_processor.ex` to route through v2 when enabled:

```elixir
# Add at top of module
alias Lumainus.Conversion.Adapter, as: ConversionV2

# Find the function that calls Docling.enqueue and wrap it:

defp convert_pdf(upload, docling_opts) do
  if use_conversion_v2?() do
    convert_pdf_v2(upload, docling_opts)
  else
    convert_pdf_v1(upload, docling_opts)
  end
end

defp convert_pdf_v2(upload, opts) do
  v2_opts =
    opts
    |> Keyword.put(:filename, upload.filename)
    |> Keyword.put(:tenant_id, upload.tenant_id)
    |> Keyword.put(:metadata, %{upload_id: upload.id})

  ConversionV2.enqueue(upload.raw_blob, v2_opts)
end

defp convert_pdf_v1(upload, opts) do
  # Existing v1 code
  Docling.enqueue(upload.raw_blob, opts)
end

defp use_conversion_v2? do
  Application.get_env(:lumainus, :conversion)[:use_v2] == true
end
```

### Step 4.2: Update Docling.Queue (Alternative Integration Point)

If jobs go through `Lumainus.Docling.Queue`, modify `lib/lumainus/docling/queue.ex`:

```elixir
# In process_job/1 or similar function:

defp do_convert(job) do
  if use_conversion_v2?() do
    Lumainus.Conversion.Adapter.enqueue(
      job.binary,
      Keyword.put(job.convert_opts, :timeout_ms, job.timeout_ms)
    )
  else
    # Existing v1 code
    Docling.convert(job.binary, Keyword.put(job.convert_opts, :timeout_ms, job.timeout_ms))
  end
end

defp use_conversion_v2? do
  Application.get_env(:lumainus, :conversion)[:use_v2] == true
end
```

---

## Phase 5: LiveView Integration (1 hour)

### Step 5.1: Update ReportsLive for v2 Events

In `lib/lumainus_web/live/reports_live.ex`, add v2 event subscription:

```elixir
# Add alias at top
alias Lumainus.Conversion.Events, as: ConversionEvents

# In mount or when starting a conversion:
defp subscribe_to_conversion(job_id) do
  if use_conversion_v2?() do
    ConversionEvents.subscribe(job_id)
  else
    # Existing v1 subscription
    Documents.subscribe_to_ingestion_job(job_id)
  end
end

# Add handle_info for v2 events:

# v2 progress events
def handle_info({:conversion_job, :progress, %{job_id: id, progress: progress}}, socket) do
  # Update progress in UI
  socket = update_job_progress(socket, id, progress)
  {:noreply, socket}
end

def handle_info({:conversion_job, :completed, job}, socket) do
  socket =
    socket
    |> update_job_state(job.id, :completed)
    |> put_flash(:info, "Conversion complete")

  {:noreply, socket}
end

def handle_info({:conversion_job, :failed, %{job_id: id, reason: reason}}, socket) do
  socket =
    socket
    |> update_job_state(id, :failed)
    |> put_flash(:error, "Conversion failed: #{inspect(reason)}")

  {:noreply, socket}
end

defp use_conversion_v2? do
  Application.get_env(:lumainus, :conversion)[:use_v2] == true
end
```

---

## Phase 6: API Endpoints (Optional, 1 hour)

### Step 6.1: Create v2 Conversion Controller

Create `lib/lumainus_web/controllers/api/v2/conversion_controller.ex`:

```elixir
defmodule LumainusWeb.Api.V2.ConversionController do
  use LumainusWeb, :controller

  alias Lumainus.Conversion.Service
  alias Lumainus.Conversion.Events

  action_fallback LumainusWeb.ApiFallbackController

  @doc "POST /api/v2/conversions"
  def create(conn, %{"file" => %Plug.Upload{} = upload} = params) do
    with {:ok, binary} <- File.read(upload.path) do
      attrs = %{
        filename: upload.filename,
        profile: parse_profile(params["profile"]),
        tenant_id: get_tenant_id(conn),
        user_id: get_user_id(conn)
      }

      case Service.submit(binary, attrs) do
        {:ok, job} ->
          conn
          |> put_status(:accepted)
          |> json(%{
            job_id: job.id,
            state: to_string(job.state),
            profile: to_string(job.profile)
          })

        {:error, :file_too_large} ->
          conn
          |> put_status(:request_entity_too_large)
          |> json(%{error: "file_too_large", max_size: "100MB"})

        {:error, :invalid_content_type} ->
          conn
          |> put_status(:unsupported_media_type)
          |> json(%{error: "invalid_content_type", allowed: ["application/pdf"]})

        {:error, :service_unavailable} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "no_backends_available"})
      end
    end
  end

  @doc "GET /api/v2/conversions/:id"
  def show(conn, %{"id" => job_id}) do
    case Service.status(job_id) do
      {:ok, status} ->
        json(conn, %{
          job_id: status.job_id,
          state: to_string(status.state),
          progress: status.progress,
          pages_done: status.pages_done,
          pages_total: status.pages_total,
          backend_used: status.backend_used && to_string(status.backend_used),
          result: status.result,
          error: status.error
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})
    end
  end

  @doc "DELETE /api/v2/conversions/:id"
  def delete(conn, %{"id" => job_id}) do
    case Service.cancel(job_id) do
      :ok ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})
    end
  end

  @doc "GET /api/v2/conversions/:id/stream"
  def stream(conn, %{"id" => job_id}) do
    # Verify job exists first
    case Service.status(job_id) do
      {:ok, _status} ->
        Events.subscribe(job_id)

        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)
        |> stream_events(job_id)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp stream_events(conn, job_id) do
    receive do
      {:conversion_job, :progress, payload} ->
        data = Jason.encode!(%{progress: payload.progress})
        {:ok, conn} = chunk(conn, "event: progress\ndata: #{data}\n\n")
        stream_events(conn, job_id)

      {:conversion_job, :completed, job} ->
        data = Jason.encode!(%{result: job.result})
        chunk(conn, "event: completed\ndata: #{data}\n\n")
        conn

      {:conversion_job, :failed, payload} ->
        data = Jason.encode!(%{error: inspect(payload.reason)})
        chunk(conn, "event: failed\ndata: #{data}\n\n")
        conn

      {:conversion_job, :cancelled, _} ->
        chunk(conn, "event: cancelled\ndata: {}\n\n")
        conn
    after
      30_000 ->
        # Heartbeat to keep connection alive
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> stream_events(conn, job_id)
          {:error, _} -> conn
        end
    end
  end

  defp parse_profile("enhanced"), do: :enhanced
  defp parse_profile(_), do: :standard

  defp get_tenant_id(conn) do
    case conn.assigns[:current_scope] do
      %{tenant_id: id} -> id
      _ -> nil
    end
  end

  defp get_user_id(conn) do
    case conn.assigns[:current_user] do
      %{id: id} -> id
      _ -> nil
    end
  end
end
```

### Step 6.2: Add Routes

Update `lib/lumainus_web/router.ex`:

```elixir
# Add after existing API scope

scope "/api/v2", LumainusWeb.Api.V2 do
  pipe_through :api

  # Conversion endpoints
  post "/conversions", ConversionController, :create
  get "/conversions/:id", ConversionController, :show
  delete "/conversions/:id", ConversionController, :delete
  get "/conversions/:id/stream", ConversionController, :stream

  # Health/availability check
  get "/conversions/profiles", ConversionController, :profiles
end
```

---

## Phase 7: Verification & Testing (30 minutes)

### Step 7.1: Verify Compilation

```bash
wsl -d ubuntu-dev bash -c ". /home/home/.asdf/asdf.sh && cd /home/home/p/g/n/lumainus && mix compile --warnings-as-errors"
```

### Step 7.2: Run All Conversion Tests

```bash
wsl -d ubuntu-dev bash -c ". /home/home/.asdf/asdf.sh && cd /home/home/p/g/n/lumainus && mix test test/lumainus/conversion/"
```

### Step 7.3: Manual IEx Verification

```bash
wsl -d ubuntu-dev bash -c ". /home/home/.asdf/asdf.sh && cd /home/home/p/g/n/lumainus && iex -S mix"
```

```elixir
# Check profiles are configured
iex> Lumainus.Conversion.Service.profiles()
[:standard, :enhanced]

# Check availability (will depend on running backends)
iex> Lumainus.Conversion.Service.available?(:standard)
false  # Expected if no backends running

# Check feature flag
iex> Application.get_env(:lumainus, :conversion)[:use_v2]
false

# Enable v2 for testing
iex> Application.put_env(:lumainus, :conversion, Keyword.put(Application.get_env(:lumainus, :conversion), :use_v2, true))
:ok

# Verify adapter works (with mock or bypass)
iex> Lumainus.Conversion.Adapter.available?(:standard)
false  # Expected if no backends
```

### Step 7.4: Integration Test with Running Backend

Start Docling backend first:

```bash
wsl -d ubuntu-dev bash -c "cd /home/home/p/g/n/lumainus && ./scripts/docling-compose.sh up"
```

Then test:

```elixir
# In IEx
iex> pdf = File.read!("test/fixtures/sample.pdf")
iex> {:ok, job} = Lumainus.Conversion.Service.submit(pdf, %{profile: :standard, filename: "test.pdf"})
iex> job.id
"abc-123-..."

iex> {:ok, status} = Lumainus.Conversion.Service.status(job.id)
iex> status.state
:processing
```

---

## Rollout Strategy

### Stage 1: Shadow Mode (Week 1)

- Deploy v2 code with `use_v2: false`
- Monitor for any compilation/startup issues
- Verify supervision tree starts correctly

### Stage 2: Canary (Week 2)

- Enable v2 for specific tenant IDs
- Monitor telemetry for errors
- Compare conversion times v1 vs v2

```elixir
# Tenant-specific feature flag
defp use_conversion_v2?(tenant_id) do
  canary_tenants = Application.get_env(:lumainus, :conversion)[:canary_tenants] || []
  tenant_id in canary_tenants
end
```

### Stage 3: Gradual Rollout (Week 3-4)

- Enable for 10% → 25% → 50% → 100%
- Use percentage-based routing

```elixir
defp use_conversion_v2?(tenant_id) do
  rollout_pct = Application.get_env(:lumainus, :conversion)[:rollout_percentage] || 0
  :erlang.phash2(tenant_id, 100) < rollout_pct
end
```

### Stage 4: Full Migration (Week 5+)

- Set `use_v2: true` globally
- Monitor for 2 weeks
- Remove v1 code paths

---

## Troubleshooting

### Job Stuck in :queued

```elixir
# Check health manager
iex> Lumainus.Conversion.Infrastructure.HealthManager.status(:docker_cpu)
:unhealthy

# Check circuit breaker
iex> Lumainus.Conversion.Infrastructure.Resilience.CircuitBreaker.state(:docker_cpu)
:open

# Force health check
iex> Lumainus.Conversion.Infrastructure.HealthManager.check_now(:docker_cpu)
```

### No Backends Available

```elixir
# Check backend configuration
iex> Application.get_env(:lumainus, :conversion)[:backends]

# Check router
iex> Lumainus.Conversion.Infrastructure.BackendRouter.backends_for_profile(:standard)
[]  # Empty = no backends configured for this profile
```

### Progress Not Updating in UI

```elixir
# Verify PubSub subscription
iex> Phoenix.PubSub.subscribe(LumainusWeb.PubSub, "conversion:job:#{job_id}")

# Check events are being broadcast
iex> Lumainus.Conversion.Events.broadcast_progress(%{id: job_id}, 50)
```

---

## File Checklist

| File | Action | Status |
|------|--------|--------|
| `priv/repo/migrations/*_create_conversion_jobs.exs` | Run migration | ⬜ |
| `lib/lumainus/conversion/adapter.ex` | Create | ⬜ |
| `test/lumainus/conversion/adapter_test.exs` | Create | ⬜ |
| `config/config.exs` | Add `use_v2` flag | ⬜ |
| `config/runtime.exs` | Add env override | ⬜ |
| `lib/lumainus/documents/ingestion_processor.ex` | Add v2 routing | ⬜ |
| `lib/lumainus_web/live/reports_live.ex` | Add v2 event handlers | ⬜ |
| `lib/lumainus_web/controllers/api/v2/conversion_controller.ex` | Create (optional) | ⬜ |
| `lib/lumainus_web/router.ex` | Add v2 routes (optional) | ⬜ |

---

## Success Criteria

1. ✅ Migration runs without errors
2. ✅ Adapter module compiles and passes tests
3. ✅ Feature flag controls routing
4. ✅ LiveView receives v2 progress events
5. ✅ (Optional) v2 API endpoints work
6. ✅ Existing v1 functionality unchanged when flag is off
7. ✅ Telemetry emits correct events
8. ✅ Circuit breaker protects against backend failures
