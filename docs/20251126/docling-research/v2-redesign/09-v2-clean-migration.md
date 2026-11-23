# Conversion System v2 - Clean Migration Plan

**Status**: Ready for Implementation
**Approach**: Full replacement of v1 (no legacy compatibility needed)
**Date**: November 26, 2025

---

## Executive Summary

With no legacy constraints, we can do a clean migration from v1 to v2:

1. **Keep**: VastAI infrastructure (InstanceManager, ActivityTracker, etc.) - v2 already uses these
2. **Keep**: Settings infrastructure (extend for v2)
3. **Remove**: All v1 conversion code (Queue, HTTP, SSEConsumer, Backends)
4. **Update**: Admin UIs to use v2 HealthManager and Services
5. **Integrate**: Documents module calls v2 Service directly

---

## Architecture Comparison

### Before (v1)

```
Documents.queue_ingestion()
         │
         ▼
    Oban Job
         │
         ▼
  Docling.Queue ──────────► Docling.enqueue()
                                   │
                                   ▼
                            Docling.HTTP
                                   │
                                   ▼
                         Docling.Backends.*
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
               Local.ex       Remote.ex     VastAI.ex
                    │              │              │
                    └──────────────┴──────┬───────┘
                                          │
                                          ▼
                                   Docling Backend
```

### After (v2)

```
Documents.queue_ingestion()
         │
         ▼
    Oban Job
         │
         ▼
  Conversion.Service.submit()
         │
         ├──► JobTracker (DB + ETS)
         │
         ├──► BackendRouter
         │         │
         │         ├──► HealthManager (health status)
         │         │
         │         └──► CircuitBreaker (failure protection)
         │
         └──► Backend.enqueue()
                    │
              ┌─────┴─────┐
              ▼           ▼
        LocalBackend  CloudBackend
              │           │
              │           └──► VastAI.InstanceManager (existing)
              │
              ▼
        HTTP.Client ──► Docling Service
```

---

## File Classification

### KEEP - VastAI Infrastructure (v2 CloudBackend uses these)

```
lib/medlum/docling/vast_ai/
├── instance_manager.ex    # Manages Vast.ai instances - CloudBackend delegates here
├── activity_tracker.ex    # Tracks conversion activity for auto-shutdown
├── provisioning_state.ex  # PubSub state for provisioning UI
├── auto_shutdown.ex       # Auto-destroys idle instances
└── start_tracker.ex       # Tracks instance start times
```

### KEEP - Settings Infrastructure (extend for v2)

```
lib/medlum/docling/
├── settings.ex            # Context module - extend to support v2
└── setting.ex             # Ecto schema - add v2 fields
```

### KEEP - Admin UIs (update for v2)

```
lib/medlum_web/live/admin/
├── docling_settings_live.ex  # Update to use v2 HealthManager
└── vast_ai_live.ex           # Keep as-is (uses InstanceManager)
```

### REMOVE - Replaced by v2

```
lib/medlum/docling/
├── http.ex                # → v2 Infrastructure.HTTP.Client
├── sse_consumer.ex        # → v2 Infrastructure.HTTP.SSEStream
├── queue.ex               # → v2 Service
├── backend.ex             # → v2 Backend behaviour
├── health_check.ex        # → v2 HealthManager (optional: keep for history)
├── health_check_worker.ex # → v2 HealthManager (remove Oban worker)
└── backends/
    ├── local.ex           # → v2 Backends.LocalBackend
    ├── remote.ex          # → v2 Backends.LocalBackend (was just different URL)
    └── vast_ai.ex         # → v2 Backends.CloudBackend

lib/medlum/
└── docling.ex             # → v2 Service (main facade)
```

### MODIFY - Integration Points

```
lib/medlum/
├── documents.ex                    # queue_ingestion → Service.submit
├── documents/ingestion_processor.ex # Docling.enqueue → Service.submit
└── application.ex                  # Remove v1 workers, keep v2 supervision

lib/medlum_web/live/
└── reports_live.ex                 # Subscribe to v2 Events
```

---

## Settings Schema Extension

Add to `docling_settings` table:

```elixir
# Migration: add_v2_fields_to_docling_settings.exs

alter table(:docling_settings) do
  # v2 profile configuration (JSON maps)
  add :v2_profile_backends, :map, default: %{
    "standard" => ["docker_cpu", "local_cpu"],
    "enhanced" => ["docker_gpu", "local_gpu", "cloud"]
  }
end
```

Update `Setting` schema:

```elixir
field(:v2_profile_backends, :map, default: %{
  "standard" => ["docker_cpu", "local_cpu"],
  "enhanced" => ["docker_gpu", "local_gpu", "cloud"]
})
```

---

## BackendRouter Integration with Settings

The key change: `BackendRouter` reads URLs from DB settings instead of static config.

```elixir
defmodule Medlum.Conversion.Infrastructure.BackendRouter do
  alias Medlum.Docling.Settings

  @doc """
  Get all backends configured for a profile.
  Reads URLs from database settings (admin-configurable).
  """
  def backends_for_profile(profile) do
    {:ok, setting} = Settings.fetch_or_init()

    # Get profile -> backend mapping from DB
    profile_backends = get_profile_backends(setting, profile)

    # Build backend info with URLs from DB
    Enum.map(profile_backends, fn backend_name ->
      build_backend_from_settings(backend_name, setting)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp get_profile_backends(setting, profile) do
    profiles = setting.v2_profile_backends || default_profiles()
    Map.get(profiles, to_string(profile), [])
  end

  defp build_backend_from_settings(backend_name, setting) do
    endpoint = get_endpoint(backend_name, setting)
    type = get_backend_type(backend_name)

    if endpoint || type == :cloud do
      %{
        name: String.to_atom(backend_name),
        module: module_for_type(type),
        endpoint: endpoint,
        backend_type: type
      }
    else
      nil  # Skip backends without configured endpoints
    end
  end

  defp get_endpoint("docker_cpu", s), do: s.docker_cpu_url
  defp get_endpoint("docker_gpu", s), do: s.docker_gpu_url
  defp get_endpoint("local_cpu", s), do: s.native_cpu_url
  defp get_endpoint("local_gpu", s), do: s.native_gpu_url
  defp get_endpoint("cloud", _s), do: nil  # CloudBackend gets URL from InstanceManager
  defp get_endpoint(_, _), do: nil

  defp get_backend_type("cloud"), do: :cloud
  defp get_backend_type(_), do: :local
end
```

---

## Admin UI Updates

### `/admin/docling` - DoclingSettingsLive

Update to use v2 HealthManager for health status:

```elixir
defp check_backend_health(backend) do
  alias Medlum.Conversion.Infrastructure.HealthManager
  alias Medlum.Conversion.Infrastructure.Resilience.CircuitBreaker

  health = HealthManager.status(backend)
  breaker = CircuitBreaker.state(backend)
  latency = HealthManager.latency(backend)

  %{
    status: health_to_status(health),
    circuit: breaker,
    latency_ms: latency,
    details: %{}
  }
end

defp health_to_status(:healthy), do: "healthy"
defp health_to_status(:unhealthy), do: "unreachable"
defp health_to_status(:unknown), do: "unknown"
```

Add circuit breaker status to health cards:

```heex
<div class="mt-1 text-xs">
  Circuit: <span class={"font-medium #{breaker_color(@health.circuit)}"}>{@health.circuit}</span>
</div>
```

### `/admin/vast_ai` - VastAILive

Keep as-is. It manages Vast.ai instances via `InstanceManager`, which v2 `CloudBackend` already uses.

---

## Integration Flow

### Documents Module

```elixir
# lib/medlum/documents.ex

def queue_ingestion(%DocumentUpload{} = upload, template, opts \\ []) do
  alias Medlum.Conversion.Service

  # Determine profile based on backend preference
  profile = profile_from_opts(opts)

  # Build conversion attributes
  attrs = %{
    profile: profile,
    filename: upload.filename,
    byte_size: byte_size(upload.raw_blob),
    tenant_id: upload.tenant_id,
    user_id: opts[:user_id],
    metadata: %{
      upload_id: upload.id,
      template_id: template.id
    }
  }

  # Submit to v2 conversion service
  case Service.submit(upload.raw_blob, attrs) do
    {:ok, job} ->
      # Create ingestion job record linking to conversion job
      create_ingestion_job(upload, job, template)
      {:ok, job}

    {:error, reason} ->
      {:error, reason}
  end
end

defp profile_from_opts(opts) do
  case Keyword.get(opts, :backend) do
    b when b in [:docker_gpu, :local_gpu, :vast_ai, :cloud] -> :enhanced
    _ -> :standard
  end
end
```

### ReportsLive

```elixir
# Subscribe to v2 events
alias Medlum.Conversion.Events

def handle_event("start_conversion", %{"upload_id" => id}, socket) do
  upload = get_upload(id)

  case Documents.queue_ingestion(upload, socket.assigns.template) do
    {:ok, job} ->
      # Subscribe to v2 conversion events
      Events.subscribe(job.id)
      {:noreply, put_flash(socket, :info, "Conversion started")}

    {:error, reason} ->
      {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
  end
end

# Handle v2 progress events
def handle_info({:conversion_job, :progress, payload}, socket) do
  {:noreply, update_progress(socket, payload.job_id, payload.progress)}
end

def handle_info({:conversion_job, :completed, job}, socket) do
  {:noreply, handle_completion(socket, job)}
end

def handle_info({:conversion_job, :failed, payload}, socket) do
  {:noreply, handle_failure(socket, payload)}
end
```

---

## Removal Checklist

### Phase 1: Stop Using v1

1. Update `Documents.queue_ingestion/3` to use v2 Service
2. Update `ReportsLive` to use v2 Events
3. Update `DoclingSettingsLive` to use v2 HealthManager
4. Remove `Docling.HealthCheckWorker` from Oban config

### Phase 2: Remove v1 Files

```bash
# Remove v1 conversion code
rm lib/medlum/docling.ex
rm lib/medlum/docling/http.ex
rm lib/medlum/docling/sse_consumer.ex
rm lib/medlum/docling/queue.ex
rm lib/medlum/docling/backend.ex
rm lib/medlum/docling/health_check_worker.ex
rm -rf lib/medlum/docling/backends/

# Remove v1 tests
rm -rf test/medlum/docling/

# Keep VastAI infrastructure
# Keep settings
# Keep health_check.ex if you want history
```

### Phase 3: Clean Up References

1. Remove `alias Medlum.Docling` from all files
2. Update any remaining `Docling.*` calls
3. Remove unused config keys from `config/config.exs`

---

## Testing Strategy

### Unit Tests (Existing - 213 passing)

All v2 core tests continue to pass.

### Integration Tests (New)

```elixir
# test/medlum/documents_integration_test.exs
describe "queue_ingestion/3 with v2" do
  test "submits to conversion service"
  test "creates ingestion job linked to conversion job"
  test "handles service unavailable gracefully"
end

# test/medlum_web/live/reports_live_v2_test.exs
describe "conversion with v2 service" do
  test "receives progress events"
  test "handles completion"
  test "handles failure"
end

# test/medlum_web/live/admin/docling_settings_v2_test.exs
describe "health display with v2 HealthManager" do
  test "shows health status from HealthManager"
  test "shows circuit breaker state"
  test "shows latency"
end
```

### Manual Integration Tests (HITL)

1. Start Docling backend (`./scripts/docling-compose.sh up`)
2. Upload PDF through ReportsLive
3. Verify progress updates in real-time
4. Verify completion stores result
5. Check `/admin/docling` shows v2 health
6. Test circuit breaker by stopping backend

---

## Success Criteria

1. All v2 core tests pass (213+)
2. All new integration tests pass
3. Documents.queue_ingestion uses v2 Service
4. ReportsLive receives v2 Events
5. Admin UI shows v2 HealthManager data
6. No references to removed v1 code remain
7. `mix compile --warnings-as-errors` passes
8. Manual HITL tests pass
