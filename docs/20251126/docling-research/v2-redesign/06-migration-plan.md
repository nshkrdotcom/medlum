# v2 Migration Plan

**Date:** November 26, 2025

---

## Overview

This document outlines a phased migration from the current monolithic Docling integration to the v2 clean architecture. The migration is designed to:

1. **Minimize risk** - Parallel implementation with feature flags
2. **Enable rollback** - Old code remains until new code is validated
3. **Maintain availability** - No downtime during migration
4. **Allow incremental progress** - Each phase is independently deployable

---

## Migration Phases

```
Week 1          Week 2          Week 3          Week 4          Week 5
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│ Phase 1  │    │ Phase 2  │    │ Phase 3  │    │ Phase 4  │    │ Phase 5  │
│ Core     │───▶│ Resilience│───▶│ Telemetry│───▶│ UI       │───▶│ Cleanup  │
│ Domain   │    │ Patterns │    │ & Tests  │    │ Refactor │    │ & Launch │
└──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘
```

---

## Phase 1: Core Domain (Week 1)

### Goals
- Create new module structure
- Implement domain layer (value objects, policies)
- Create service facade with dual path support
- No changes to existing code yet

### Tasks

#### 1.1 Create Directory Structure

```bash
mkdir -p lib/medlum/conversion/{application,infrastructure/{backends,resilience,http,telemetry},adapters}
mkdir -p test/medlum/conversion/{application,infrastructure}
```

#### 1.2 Implement Domain Layer

```elixir
# lib/medlum/conversion/job.ex
# lib/medlum/conversion/job_status.ex
# lib/medlum/conversion/processing_profile.ex
# lib/medlum/conversion/policy.ex
```

**Tests:**
```elixir
# test/medlum/conversion/job_test.exs
# test/medlum/conversion/job_status_test.exs
# test/medlum/conversion/policy_test.exs
```

#### 1.3 Create Service Facade (Dual Path)

```elixir
defmodule Medlum.Conversion.Service do
  @moduledoc """
  New conversion service with feature flag for v1/v2 path.
  """

  def submit(binary, opts) do
    if use_v2?() do
      v2_submit(binary, opts)
    else
      # Delegate to existing Docling module
      v1_submit(binary, opts)
    end
  end

  defp use_v2? do
    Application.get_env(:medlum, :conversion_v2_enabled, false)
  end

  defp v1_submit(binary, opts) do
    # Wrap existing Docling.enqueue/2 call
    Medlum.Docling.enqueue(binary, convert_opts_v1(opts))
  end

  defp v2_submit(binary, opts) do
    # New implementation (stub for now)
    {:error, :not_implemented}
  end
end
```

#### 1.4 Add Feature Flag Configuration

```elixir
# config/config.exs
config :medlum, :conversion_v2_enabled, false

# config/dev.exs
config :medlum, :conversion_v2_enabled, System.get_env("CONVERSION_V2") == "1"
```

### Deliverables
- [ ] Domain value objects with tests
- [ ] Service facade with v1 passthrough
- [ ] Feature flag infrastructure
- [ ] No production impact

### Verification
```bash
# Run new tests
mix test test/medlum/conversion/

# Verify v1 path still works
CONVERSION_V2=0 mix test test/medlum/docling/
```

---

## Phase 2: Resilience Patterns (Week 2)

### Goals
- Implement circuit breaker
- Implement retry policy
- Implement health manager
- Configure connection pools

### Tasks

#### 2.1 Circuit Breaker

```elixir
# lib/medlum/conversion/infrastructure/resilience/circuit_breaker.ex
# test/medlum/conversion/infrastructure/circuit_breaker_test.exs
```

#### 2.2 Retry Policy

```elixir
# lib/medlum/conversion/infrastructure/resilience/retry_policy.ex
# test/medlum/conversion/infrastructure/retry_policy_test.exs
```

#### 2.3 Health Manager

```elixir
# lib/medlum/conversion/infrastructure/health_manager.ex
# test/medlum/conversion/infrastructure/health_manager_test.exs
```

#### 2.4 Connection Pool Configuration

```elixir
# lib/medlum/conversion/infrastructure/connection_pool.ex

# Update application.ex
def start(_type, _args) do
  children = [
    # ... existing children ...
    {Medlum.Conversion.Infrastructure.ConnectionPool, []},
    {Registry, keys: :unique, name: Medlum.Conversion.Registry}
  ]
end
```

#### 2.5 Backend Router with Resilience

```elixir
# lib/medlum/conversion/infrastructure/backend_router.ex
# - Uses circuit breaker
# - Uses health manager
# - Implements failover
```

### Deliverables
- [ ] Circuit breaker with tests (including property tests)
- [ ] Retry policy with tests
- [ ] Health manager with tests
- [ ] Connection pool configuration
- [ ] Backend router integrating all patterns

### Verification
```bash
# Run resilience tests
mix test test/medlum/conversion/infrastructure/

# Property tests
mix test --only property
```

---

## Phase 3: Telemetry & Full Backend Implementation (Week 3)

### Goals
- Add telemetry events throughout
- Implement local and cloud backends
- Implement SSE stream with reconnection
- Complete test coverage

### Tasks

#### 3.1 Telemetry Infrastructure

```elixir
# lib/medlum/conversion/infrastructure/telemetry/emitter.ex
# lib/medlum/conversion/infrastructure/telemetry/metrics.ex
# lib/medlum/conversion/infrastructure/telemetry/handler.ex
```

#### 3.2 HTTP Client with Telemetry

```elixir
# lib/medlum/conversion/infrastructure/http/client.ex
# - Wraps Req/Finch
# - Emits telemetry events
# - Uses connection pool
```

#### 3.3 Backend Implementations

```elixir
# lib/medlum/conversion/infrastructure/backends/local_backend.ex
# lib/medlum/conversion/infrastructure/backends/cloud_backend.ex
```

#### 3.4 SSE Stream with Reconnection

```elixir
# lib/medlum/conversion/infrastructure/http/sse_stream.ex
```

#### 3.5 Complete Service Implementation

Wire up v2 path in service:

```elixir
defp v2_submit(binary, opts) do
  with :ok <- Policy.validate_file(binary, opts[:filename]),
       job <- Job.new(build_job_attrs(binary, opts)),
       :ok <- JobTracker.register(job),
       {:ok, _} <- BackendRouter.route(job, binary) do
    {:ok, job}
  end
end
```

### Deliverables
- [ ] Telemetry emitter with all events
- [ ] Metrics definitions
- [ ] HTTP client with telemetry
- [ ] Local backend implementation
- [ ] Cloud backend implementation
- [ ] SSE stream with reconnection
- [ ] Integration tests

### Verification
```bash
# Full test suite
mix test

# Verify telemetry events
mix test test/medlum/conversion/infrastructure/telemetry/

# Enable v2 in dev
CONVERSION_V2=1 mix phx.server
```

---

## Phase 4: UI Refactoring (Week 4)

### Goals
- Create user-facing components
- Refactor ReportsLive
- Migrate user preferences
- Update PubSub events

### Tasks

#### 4.1 Create Components

```elixir
# lib/medlum_web/components/conversion.ex
# - profile_selector
# - job_status
# - availability_indicator
# - progress_bar
```

#### 4.2 Database Migration

```elixir
# priv/repo/migrations/XXX_simplify_processing_preference.exs
defmodule Medlum.Repo.Migrations.SimplifyProcessingPreference do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :processing_profile, :string, default: "standard"
    end

    # Note: docling_backend removed in cleanup phase
  end
end
```

#### 4.3 Refactor ReportsLive

Create new version alongside old:

```elixir
# lib/medlum_web/live/reports_live_v2.ex
# - Uses ConversionService
# - Uses new components
# - No backend knowledge
```

#### 4.4 Feature Flag for UI

```elixir
# In router or plug
if use_v2_ui?(conn) do
  live "/reports", ReportsLiveV2
else
  live "/reports", ReportsLive
end
```

#### 4.5 Update Events

```elixir
# lib/medlum/conversion/events.ex
# - User-friendly events
# - No backend details in payloads
```

### Deliverables
- [ ] Conversion components
- [ ] Database migration (additive only)
- [ ] ReportsLiveV2
- [ ] Event system refactoring
- [ ] UI feature flag

### Verification
```bash
# Test new UI
CONVERSION_V2_UI=1 mix phx.server

# A/B comparison
# 1. Open /reports with v1
# 2. Open /reports with v2
# 3. Compare behavior and UI
```

---

## Phase 5: Cleanup & Launch (Week 5)

### Goals
- Enable v2 for all users
- Remove v1 code
- Remove feature flags
- Final documentation

### Tasks

#### 5.1 Gradual Rollout

```elixir
# Enable for percentage of users
config :medlum, :conversion_v2_rollout_percent, 10  # Start at 10%

defp use_v2?(user) do
  if Application.get_env(:medlum, :conversion_v2_enabled) do
    true
  else
    # Gradual rollout based on user ID
    percent = Application.get_env(:medlum, :conversion_v2_rollout_percent, 0)
    :erlang.phash2(user.id, 100) < percent
  end
end
```

#### 5.2 Monitoring

During rollout, monitor:
- Error rates (v1 vs v2)
- Latency (v1 vs v2)
- Success rates
- User feedback

```promql
# Compare error rates
sum(rate(medlum_conversion_job_failed_count{version="v2"}[5m]))
/
sum(rate(medlum_conversion_job_failed_count{version="v1"}[5m]))
```

#### 5.3 Full Enable

Once validated at 100%:

```elixir
# config/config.exs
config :medlum, :conversion_v2_enabled, true
```

#### 5.4 Remove Old Code

```bash
# Remove old modules
rm lib/medlum/docling.ex
rm -rf lib/medlum/docling/
rm lib/medlum_web/live/reports_live.ex  # Keep v2 only

# Remove old tests
rm -rf test/medlum/docling/

# Remove feature flags
# In config files, remove :conversion_v2_enabled, :conversion_v2_rollout_percent
```

#### 5.5 Final Migration

```elixir
# priv/repo/migrations/XXX_remove_docling_backend_column.exs
defmodule Medlum.Repo.Migrations.RemoveDoclingBackendColumn do
  use Ecto.Migration

  def change do
    alter table(:users) do
      remove :docling_backend
    end
  end
end
```

#### 5.6 Rename Modules

```elixir
# Optionally move to shorter names
# Medlum.Conversion.Service -> Medlum.Conversion
# Or keep as-is for clarity
```

### Deliverables
- [ ] Gradual rollout completed
- [ ] Old code removed
- [ ] Feature flags removed
- [ ] Final migrations run
- [ ] Documentation updated

---

## Rollback Plan

### Phase 1-3 Rollback
If issues during phases 1-3:
- Set `CONVERSION_V2=0`
- All traffic uses v1 path
- No user impact

### Phase 4 Rollback
If issues during phase 4:
- Set `CONVERSION_V2_UI=0`
- Users see old UI
- Backend uses appropriate version

### Phase 5 Rollback
If issues during phase 5:
- Reduce rollout percentage
- If critical: restore old code from git
- Emergency migration to re-add removed columns

```bash
# Emergency restore
git checkout HEAD~1 -- lib/medlum/docling.ex lib/medlum/docling/
git checkout HEAD~1 -- lib/medlum_web/live/reports_live.ex
mix deps.get && mix compile
```

---

## Risk Mitigation

### Risk: Breaking Changes
**Mitigation:**
- Feature flags for all new code
- Parallel implementation
- Gradual rollout

### Risk: Performance Regression
**Mitigation:**
- Telemetry from day 1
- Benchmark tests
- A/B comparison metrics

### Risk: Data Loss
**Mitigation:**
- Additive migrations first
- Remove columns only after validation
- Database backups before cleanup

### Risk: Extended Timeline
**Mitigation:**
- Each phase is independently deployable
- Can pause between phases
- Minimum viable v2 possible at end of phase 3

---

## Success Metrics

### Functional
- [ ] All existing tests pass
- [ ] New tests pass
- [ ] Manual testing complete
- [ ] No regression in conversion success rate

### Performance
- [ ] P95 latency within 10% of v1
- [ ] Error rate <= v1 error rate
- [ ] No increase in timeout rate

### Quality
- [ ] Test coverage >= 90%
- [ ] No backend terminology in user UI
- [ ] Telemetry events for all operations
- [ ] Circuit breaker functioning

---

## Timeline Summary

| Week | Phase | Key Deliverable | Risk Level |
|------|-------|-----------------|------------|
| 1 | Core Domain | Service facade with v1 passthrough | Low |
| 2 | Resilience | Circuit breaker, retry, health | Low |
| 3 | Telemetry & Backends | Full v2 implementation | Medium |
| 4 | UI Refactoring | ReportsLiveV2, components | Medium |
| 5 | Cleanup & Launch | Production rollout | Medium-High |

---

## Post-Migration

### Documentation Updates
- Update CLAUDE.md with new architecture
- Update API documentation
- Create operator guide for monitoring

### Training
- Brief team on new architecture
- Document debugging procedures
- Update runbooks

### Monitoring
- Set up Grafana dashboards
- Configure alerts
- Establish SLOs

---

## Appendix: File Checklist

### New Files to Create

```
lib/medlum/conversion/
├── conversion.ex                    # Re-export service
├── job.ex
├── job_status.ex
├── processing_profile.ex
├── policy.ex
├── events.ex
│
├── application/
│   ├── service.ex
│   ├── job_tracker.ex
│   └── profile_resolver.ex
│
├── infrastructure/
│   ├── backend_router.ex
│   ├── health_manager.ex
│   ├── config_provider.ex
│   ├── context.ex
│   │
│   ├── backends/
│   │   ├── backend.ex
│   │   ├── local_backend.ex
│   │   └── cloud_backend.ex
│   │
│   ├── resilience/
│   │   ├── circuit_breaker.ex
│   │   ├── retry_policy.ex
│   │   ├── connection_pool.ex
│   │   └── timeout_policy.ex
│   │
│   ├── http/
│   │   ├── client.ex
│   │   └── sse_stream.ex
│   │
│   └── telemetry/
│       ├── emitter.ex
│       ├── metrics.ex
│       ├── handler.ex
│       └── span.ex
│
└── adapters/
    ├── oban_worker.ex
    └── pubsub_broadcaster.ex

lib/medlum_web/
├── components/
│   └── conversion.ex
└── live/
    └── reports_live_v2.ex

test/medlum/conversion/
├── job_test.exs
├── job_status_test.exs
├── policy_test.exs
├── service_test.exs
│
├── infrastructure/
│   ├── circuit_breaker_test.exs
│   ├── retry_policy_test.exs
│   ├── health_manager_test.exs
│   └── backend_router_test.exs
│
└── integration_test.exs

test/support/
└── conversion/
    ├── mock_backend.ex
    ├── mock_http_client.ex
    └── helpers.ex
```

### Files to Remove (Phase 5)

```
lib/medlum/docling.ex
lib/medlum/docling/
lib/medlum_web/live/reports_live.ex (keep v2)
lib/medlum_web/live/admin/docling_settings_live.ex (refactor to conversion_settings_live.ex)
test/medlum/docling/
```

### Files to Modify

```
lib/medlum/application.ex          # Add new supervisors
lib/medlum_web/router.ex           # Feature flag routing
lib/medlum/accounts/user.ex        # processing_profile field
config/config.exs                    # New configuration
config/test.exs                      # Test configuration
```
