# Implementation Roadmap

**Date:** November 28, 2025
**Approach:** Parallel development - new system alongside old, then switch

---

## Overview

We'll build the new system without touching the old one, then migrate when ready. This allows:
- Testing new system in isolation
- Gradual migration
- Rollback capability
- Zero downtime

---

## Phase 1: Foundation (New Files Only)

### 1.1 New Settings Schema

**Create:** `lib/lumainus/docling/settings_v2.ex`

```elixir
defmodule Lumainus.Docling.SettingsV2 do
  # New simplified schema (see 02-SIMPLIFIED-ARCHITECTURE.md)
  # Completely separate from existing settings
end
```

**Migration:**
```elixir
defmodule Lumainus.Repo.Migrations.CreateDoclingSettingsV2 do
  use Ecto.Migration

  def change do
    create table(:docling_settings_v2, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :mode, :string, default: "local"
      add :local_endpoint, :string, default: "http://127.0.0.1:8042"
      add :local_gpu_enabled, :boolean, default: false
      add :local_auto_manage, :boolean, default: true
      add :cloud_api_key, :string
      add :cloud_auto_provision, :boolean, default: true
      add :cloud_idle_timeout_minutes, :integer, default: 15
      add :cloud_max_price_per_hour, :decimal, default: 0.50
      add :timeout_ms, :integer, default: 300_000
      add :max_file_size_mb, :integer, default: 100
      timestamps()
    end
  end
end
```

**Tasks:**
- [ ] Create `settings_v2.ex` schema
- [ ] Create migration
- [ ] Run migration
- [ ] Add seed data

---

### 1.2 Local Manager

**Create:** `lib/lumainus/backends/local_manager.ex`

**Tasks:**
- [ ] Create GenServer structure
- [ ] Implement Docker detection (`docker info`)
- [ ] Implement container existence check
- [ ] Implement container creation
- [ ] Implement container start/stop
- [ ] Implement health check loop
- [ ] Implement PubSub broadcast
- [ ] Add to supervision tree (disabled by default)

**Test independently:**
```elixir
# In IEx
LocalManager.start_link([])
LocalManager.ensure_running()
LocalManager.health()
LocalManager.get_endpoint()
```

---

### 1.3 Cloud Manager

**Create:** `lib/lumainus/backends/cloud_manager.ex`

**Tasks:**
- [ ] Create GenServer structure
- [ ] Implement Vast.ai sync on startup
- [ ] Implement instance recovery
- [ ] Implement auto-provision
- [ ] Implement start/stop
- [ ] Implement idle timeout
- [ ] Implement health check
- [ ] Implement PubSub broadcast
- [ ] Add to supervision tree (disabled by default)

**Test independently:**
```elixir
# In IEx (with VASTAI_API_KEY set)
CloudManager.start_link([])
CloudManager.status()
CloudManager.ensure_running()
CloudManager.health()
```

---

### 1.4 Backend Router

**Create:** `lib/lumainus/backends/router.ex`

**Tasks:**
- [ ] Create module with `get_endpoint/1`
- [ ] Implement mode-based routing
- [ ] Implement health check + ensure running flow
- [ ] Add force_cloud option

**Test:**
```elixir
Router.get_endpoint()
Router.get_endpoint(force_cloud: true)
```

---

## Phase 2: Processing Pipeline (New Files Only)

### 2.1 Simplified Processor

**Create:** `lib/lumainus/documents/processor_v2.ex`

**Tasks:**
- [ ] Create process/1 function
- [ ] Implement stage-based progress
- [ ] Implement Docling submission
- [ ] Implement polling with progress
- [ ] Implement PubSub broadcasts
- [ ] Handle errors gracefully

---

### 2.2 Oban Worker

**Create:** `lib/lumainus/workers/document_worker_v2.ex`

**Tasks:**
- [ ] Create Oban worker
- [ ] Configure queue
- [ ] Set max_attempts: 3
- [ ] Set timeout based on settings

---

### 2.3 Documents Context Extension

**Modify:** `lib/lumainus/documents.ex` (add functions, don't change existing)

**Tasks:**
- [ ] Add `queue_processing_v2/1`
- [ ] Add `get_job!/1`
- [ ] Add `save_conversion_result/2`
- [ ] Keep all existing functions untouched

---

## Phase 3: Upload Page (New Route)

### 3.1 LiveView

**Create:** `lib/lumainus_web/live/upload_live.ex`

**Tasks:**
- [ ] Create mount with subscriptions
- [ ] Implement file upload handling
- [ ] Implement progress tracking
- [ ] Implement completion display
- [ ] Implement error handling
- [ ] Add PubSub handlers

---

### 3.2 CSS

**Create:** `assets/css/upload.css`

**Tasks:**
- [ ] Dropzone styles
- [ ] Progress bar styles
- [ ] Status indicator styles
- [ ] Responsive design

---

### 3.3 Router

**Modify:** `lib/lumainus_web/router.ex`

**Tasks:**
- [ ] Add `/upload` route (new, separate from /reports)
- [ ] Keep `/reports` unchanged

---

## Phase 4: Testing & Validation

### 4.1 Unit Tests

**Create:** `test/lumainus/backends/`

**Tasks:**
- [ ] LocalManager tests (with mocked Docker)
- [ ] CloudManager tests (with mocked Vast.ai)
- [ ] Router tests
- [ ] ProcessorV2 tests
- [ ] WorkerV2 tests

---

### 4.2 Integration Tests

**Create:** `test/lumainus_web/live/upload_live_test.exs`

**Tasks:**
- [ ] Upload flow test
- [ ] Progress update test
- [ ] Error handling test
- [ ] Multiple file test

---

### 4.3 Manual Testing Checklist

**Local Mode:**
- [ ] App starts, Docker container auto-starts
- [ ] Upload PDF, see progress, get result
- [ ] Container crash → auto-restart → upload works
- [ ] GPU toggle works (if GPU available)

**Cloud Mode:**
- [ ] App starts, syncs with Vast.ai
- [ ] Upload PDF when no instance → provisions → processes
- [ ] Upload PDF when stopped → starts → processes
- [ ] Idle timeout → instance stops
- [ ] Price limit enforced

---

## Phase 5: Migration

### 5.1 Feature Flag

**Create:** `lib/lumainus/feature_flags.ex`

```elixir
defmodule Lumainus.FeatureFlags do
  def use_v2_docling? do
    Application.get_env(:lumainus, :use_v2_docling, false)
  end
end
```

**Config:**
```elixir
# config/dev.exs
config :lumainus, use_v2_docling: true

# config/prod.exs
config :lumainus, use_v2_docling: System.get_env("USE_V2_DOCLING") == "true"
```

---

### 5.2 Supervision Tree Update

**Modify:** `lib/lumainus/application.ex`

```elixir
def start(_type, _args) do
  children = [
    # ... existing children ...
  ] ++ v2_children()

  # ...
end

defp v2_children do
  if FeatureFlags.use_v2_docling?() do
    [
      Lumainus.Backends.LocalManager,
      Lumainus.Backends.CloudManager
    ]
  else
    []
  end
end
```

---

### 5.3 Admin Settings Migration

**Create:** Admin UI to migrate settings from v1 to v2

Or: Script to copy relevant settings:
```elixir
def migrate_settings do
  v1 = Lumainus.Docling.Settings.get()

  %Lumainus.Docling.SettingsV2{}
  |> SettingsV2.changeset(%{
    mode: if(v1.default_mode == "cloud", do: "cloud", else: "local"),
    local_endpoint: v1.docker_cpu_url,
    cloud_api_key: v1.cloud_api_key,
    # ...
  })
  |> Repo.insert()
end
```

---

### 5.4 Redirect Old Route

**Modify:** Router to redirect `/reports` → `/upload` when v2 enabled

```elixir
live "/reports", ReportsLive, :index  # Keep for now

# Add redirect after migration complete:
# get "/reports", Redirect, to: "/upload"
```

---

## Phase 6: Cleanup (After Migration Stable)

### 6.1 Remove Old Code

**Delete:**
```
lib/lumainus/docling/
├── setting.ex              # Old schema
├── settings.ex             # Old settings module
├── health_manager.ex       # Replaced
├── vast_ai/
│   ├── instance_manager.ex # 1487 lines → gone
│   ├── activity_tracker.ex
│   ├── start_tracker.ex
│   ├── auto_shutdown.ex
│   └── provisioning_state.ex

lib/lumainus/conversion/
├── backend_router.ex       # Replaced
├── processing_profile.ex   # Profiles removed
└── cloud_status.ex         # Simplified
```

**Rename:**
```
settings_v2.ex → settings.ex
processor_v2.ex → processor.ex
document_worker_v2.ex → document_worker.ex
```

---

### 6.2 Database Cleanup

**Migration:**
```elixir
def change do
  drop table(:docling_settings)  # Old table
  rename table(:docling_settings_v2), to: table(:docling_settings)
end
```

---

### 6.3 Remove Feature Flag

**Config:**
```elixir
# Remove use_v2_docling config
# Remove FeatureFlags module
# Remove conditional in application.ex
```

---

## Timeline Estimate

| Phase | Files | Complexity |
|-------|-------|------------|
| Phase 1: Foundation | 5 new files | Medium |
| Phase 2: Processing | 3 new files | Medium |
| Phase 3: Upload Page | 3 new files | Medium |
| Phase 4: Testing | 5 test files | Medium |
| Phase 5: Migration | Config changes | Low |
| Phase 6: Cleanup | Delete old files | Low |

---

## Risk Mitigation

### Risk: Docker not available on server
**Mitigation:** LocalManager detects and fails gracefully, logs clear error

### Risk: Vast.ai API changes
**Mitigation:** CloudManager has retry logic, clear error messages

### Risk: Existing jobs in queue
**Mitigation:** Both systems can run in parallel, old jobs use old worker

### Risk: Data loss during migration
**Mitigation:** Settings migration is additive, old table not deleted until verified

---

## Success Criteria

- [ ] Upload PDF in < 5 seconds
- [ ] See progress updates every 1-2 seconds
- [ ] Processing completes in < 5 minutes for typical PDF
- [ ] Zero manual intervention for local Docker
- [ ] Zero manual intervention for cloud GPU
- [ ] Error messages are clear and actionable
- [ ] Mobile-responsive design
- [ ] 95%+ success rate on uploads

---

## Files Summary

### New Files to Create

```
lib/lumainus/
├── backends/
│   ├── local_manager.ex      # NEW
│   ├── cloud_manager.ex      # NEW
│   └── router.ex             # NEW
├── docling/
│   └── settings_v2.ex        # NEW
├── documents/
│   └── processor_v2.ex       # NEW
├── workers/
│   └── document_worker_v2.ex # NEW
└── feature_flags.ex          # NEW

lib/lumainus_web/
└── live/
    └── upload_live.ex        # NEW

assets/css/
└── upload.css                # NEW

test/lumainus/
├── backends/
│   ├── local_manager_test.exs
│   ├── cloud_manager_test.exs
│   └── router_test.exs
└── documents/
    └── processor_v2_test.exs

test/lumainus_web/live/
└── upload_live_test.exs

priv/repo/migrations/
└── YYYYMMDDHHMMSS_create_docling_settings_v2.exs
```

### Files to Eventually Delete

```
lib/lumainus/docling/
├── setting.ex
├── settings.ex
├── health_manager.ex
├── vast_ai/
│   ├── instance_manager.ex   # 1487 lines
│   ├── activity_tracker.ex
│   ├── start_tracker.ex
│   ├── auto_shutdown.ex
│   └── provisioning_state.ex

lib/lumainus/conversion/
├── backend_router.ex
├── processing_profile.ex
└── cloud_status.ex
```

**Estimated line reduction:** ~3,500 lines removed, ~1,500 lines added = **net -2,000 lines**

---

## Getting Started

1. Create `docs/20251128/docling-rebuild/` ✓
2. Read this roadmap
3. Start with Phase 1.1 (SettingsV2 schema)
4. Test each component in isolation before moving on
5. Use feature flag to enable when ready
6. Test thoroughly before deleting old code
