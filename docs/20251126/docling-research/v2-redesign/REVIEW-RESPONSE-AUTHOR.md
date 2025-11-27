# Docling v2 Redesign – Author's Response to Review

**Date:** November 26, 2025
**Author:** Architecture Team
**In Response To:** REVIEW-RESPONSE.md

---

## Executive Response

The review raises valid concerns. We agree with several blocking issues and propose targeted revisions rather than rejecting the v2 direction outright. The core goals remain correct—testability, observability, resilience—but implementation details need adjustment.

**Recommendation:** Proceed with v2 after addressing the blocking issues identified. The current implementation has grown organically to ~3,500 lines of Elixir code with sophisticated features (InstanceManager state machine, Cloudflare Tunnel integration, PubSub-driven UI updates) that the v2 design must preserve, not replace wholesale.

---

## Response to Critical Issues

### 1. Traceability Regression (Blocking) — ACCEPTED

**Reviewer's Concern:** The proposal removes user/backend provenance, breaking audit trails.

**Our Response:** Correct. Upon reviewing the existing code:

- `ReportsLive` stores `docling_backend` and `docling_backend_status` in document metadata (lines 1090-1091)
- Users currently see `backend_label(doc.backend)` on documents
- The `IngestionJob` schema tracks which backend processed each job

**Resolution:**
```elixir
# Revised JobStatus struct - preserve provenance
defmodule Lumainus.Conversion.JobStatus do
  @type t :: %__MODULE__{
    # ... existing fields ...

    # ADD: Internal provenance (not shown in user UI, available for audit/debug)
    backend_used: atom(),           # :docker_cpu, :vast_ai, etc.
    backend_endpoint: String.t(),   # Actual URL used
    processed_at: DateTime.t()
  }
end

# Document metadata still stores backend provenance
# UI shows simplified "Enhanced" label but metadata preserves "vast_ai"
```

**Migration Plan Update:**
- Do NOT drop `docling_backend` from existing schemas until equivalent provenance exists
- Add `backend_used` to new JobStatus struct
- Admin/debug UI retains full backend visibility

---

### 2. Orphaned/Volatile Job Tracking (Blocking) — ACCEPTED

**Reviewer's Concern:** `Service.submit/2` has no transactional coupling with `BackendRouter.route/2`. Job→backend mapping is undefined.

**Our Response:** This is a real gap. The current `InstanceManager` (1,377 lines) maintains state in GenServer memory that is lost on restart. However, it does:
- Sync with Vast.ai on startup (`handle_info(:startup_sync, ...)`, line 814)
- Persist `cloud_url` to database (`DoclingSettings.update_cloud_url/1`, line 594)
- Track sessions via `GPU.get_session_by_instance/1`

**Resolution:** The v2 design should:

1. **Store job→backend mapping in database**, not just GenServer state:
```elixir
# Add to existing IngestionJob schema (already exists!)
# The current schema already has backend tracking, just not consistently used
```

2. **Make JobTracker wrap existing IngestionJob persistence:**
```elixir
defmodule Lumainus.Conversion.Application.JobTracker do
  # Delegate to Documents.IngestionJob for persistence
  # GenServer only holds in-flight job refs, not ground truth

  def register(job) do
    # Create IngestionJob record (DURABLE)
    # Store job_id -> backend_name mapping
    # Track in ETS for fast lookup (VOLATILE, reconstructible)
  end
end
```

3. **Leverage existing `startup_sync` pattern** from InstanceManager for job recovery

---

### 3. Circuit Breaker + Health + Routing Semantics (Major) — PARTIALLY ACCEPTED

**Reviewer's Concern:**
- All errors count as breaker failures (including 4xx)
- Half-open allows unbounded probes
- `select_best_backend/1` has undefined ordering

**Our Response:** Valid points on error classification and probe limiting.

**Corrections:**
```elixir
# 1. Error classification for circuit breaker
defp should_count_as_failure?({:http_error, status, _}) when status >= 500, do: true
defp should_count_as_failure?({:http_error, 429, _}), do: true  # Rate limited
defp should_count_as_failure?({:transport_error, _}), do: true
defp should_count_as_failure?(:timeout), do: true
defp should_count_as_failure?(_), do: false  # 4xx, etc.

# 2. Bound half-open probes
@half_open_max_concurrent 1  # Only allow 1 probe at a time

# 3. Fix backend selection ordering
defp select_best_backend(backends) do
  backends
  |> Enum.filter(&backend_available?/1)
  |> Enum.sort_by(fn backend ->
    latency = HealthManager.latency(backend)
    state_priority = case CircuitBreaker.state(backend) do
      :closed -> 0
      :half_open -> 1
      :open -> 2  # Should never reach here due to filter
    end
    # Use {priority, latency} with :infinity handled
    {state_priority, latency_value(latency)}
  end)
  |> List.first()
end

defp latency_value(:infinity), do: 999_999_999
defp latency_value(ms) when is_integer(ms), do: ms
```

**Regarding "all backends down":** The current code returns `{:error, :no_instance_provision_required}` which is appropriate—provisioning is admin-only. We'll add clearer error messaging:
```elixir
{:error, :service_unavailable, "No processing backends are currently available"}
```

---

### 4. Retry Policy May Duplicate Work (Major) — ACCEPTED

**Reviewer's Concern:** Retrying `enqueue/2` can submit duplicate jobs.

**Our Response:** Correct. The retry policy should NOT wrap enqueue operations.

**Resolution:**
```elixir
# Retry policy is for:
# - Health checks (safe)
# - Status polling (safe, idempotent)
# - await SSE reconnection (safe)

# Retry policy is NOT for:
# - convert/2 (NOT idempotent - causes double processing)
# - enqueue/2 (NOT idempotent - creates duplicate jobs)

# Instead, these use circuit breaker only:
def submit(binary, opts) do
  CircuitBreaker.call(backend, fn ->
    # No retry wrapper here
    backend_module.enqueue(binary, opts)
  end)
end
```

Document this clearly in the module:
```elixir
@moduledoc """
## Retry vs Circuit Breaker

- **RetryPolicy**: ONLY for idempotent operations (health, status, SSE reconnect)
- **CircuitBreaker**: For all backend calls (provides fast-fail, no retry)

Never wrap enqueue/convert in RetryPolicy - they are not idempotent.
"""
```

---

### 5. Observability Cardinality and Correlation (Major) — ACCEPTED

**Reviewer's Concern:**
- tenant_id/job_id/error in metrics will explode Prometheus cardinality
- No trace propagation to Python

**Our Response:** Valid concerns.

**Corrections:**

1. **Reduce metric cardinality:**
```elixir
# BAD - high cardinality
counter("lumainus.conversion.job.submitted.count", tags: [:profile, :tenant_id])

# GOOD - bounded cardinality
counter("lumainus.conversion.job.submitted.count", tags: [:profile, :backend_type])
# backend_type: :local | :cloud (not the 5 specific backends)

# Job IDs and tenant IDs go in traces/logs, NOT metrics
```

2. **Trace propagation to Python:**
```elixir
# Add trace context to HTTP headers
defp add_trace_headers(request, job) do
  trace_id = Context.get().trace_id
  span_id = Context.get().span_id

  request
  |> Req.Request.put_header("x-trace-id", trace_id)
  |> Req.Request.put_header("x-span-id", span_id)
  |> Req.Request.put_header("x-job-id", job.id)
end

# Python service logs with these headers for correlation
```

3. **Sample progress events:**
```elixir
# Don't emit telemetry for every page
@progress_sample_rate 10  # Emit every 10th progress update

def emit_progress(job_id, progress) do
  if rem(progress, @progress_sample_rate) == 0 do
    :telemetry.execute([:lumainus, :conversion, :job, :progress], ...)
  end
end
```

---

### 6. Migration/Data Risk (Major) — ACCEPTED

**Reviewer's Concern:** Removing `docling_backend` column and metadata without preservation.

**Our Response:** The migration plan needs revision.

**Corrections:**

1. **Phase 5 revision - DO NOT remove columns immediately:**
```elixir
# OLD Phase 5: Remove docling_backend column
# NEW Phase 5: Mark as deprecated but KEEP

# Migration adds new field alongside old:
alter table(:users) do
  add :processing_profile, :string, default: "standard"
  # KEEP docling_backend for now
end

# Set deadline for removal: 3 months after v2 launch
```

2. **Document metadata preservation:**
```elixir
# When storing job result:
%{
  # User-facing
  processing_profile: :enhanced,

  # Preserved for audit (hidden from user UI)
  _backend: :vast_ai,
  _backend_endpoint: "https://docling.lumainus.com",
  _instance_id: 12345
}
```

3. **Rollback includes DB state:**
```bash
# Rollback script (not just git checkout)
mix ecto.rollback --to 20251201_add_processing_profile
# This restores docling_backend as primary field
```

---

## Response to Design Concerns

### "Over-abstraction without addressing real pain"

**Reviewer's Concern:** New layering rebrands existing code without addressing Vast.ai provisioning delays, SSE flakiness.

**Our Response:** Fair criticism. We should prioritize:

1. **SSE reliability** — Current `SSEConsumer` (165 lines) has no reconnection logic. v2 proposes `SSEStream` with auto-reconnection. This is a real improvement.

2. **Vast.ai provisioning** — Current `InstanceManager` already handles this well (1,377 lines including `wait_for_instance_running/2`). v2 should preserve this, not replace it.

**Revised approach:**
- Keep existing `InstanceManager` mostly as-is
- Wrap it in new `BackendRouter` for unified interface
- Add resilience patterns (circuit breaker, health-aware routing) on TOP of existing code
- Don't rewrite what works

### "Domain/infrastructure leakage"

**Reviewer's Concern:** `TimeoutPolicy` embeds backend names; `ConversionPolicy.user_has_enhanced_access?/1` is a stub.

**Our Response:**
- `TimeoutPolicy` should use backend TYPES (`:local` vs `:cloud`), not names
- `user_has_enhanced_access?/1` needs real implementation tied to subscription/feature flags

```elixir
# Fix timeout policy
defp backend_type(:native_cpu), do: :local
defp backend_type(:native_gpu), do: :local
defp backend_type(:docker_cpu), do: :local
defp backend_type(:docker_gpu), do: :local
defp backend_type(:vast_ai), do: :cloud

def timeout_for_backend_type(:local), do: @local_timeout_ms
def timeout_for_backend_type(:cloud), do: @cloud_timeout_ms
```

### "Incomplete status model"

**Reviewer's Concern:** Missing states like "provisioning", treating unknown as `:processing`.

**Our Response:** Valid. The current `InstanceManager` has richer states: `:none`, `:running`, `:stopped`, `:loading`.

**Correction:**
```elixir
@type state ::
  :queued |           # In queue, not started
  :provisioning |     # Vast.ai instance spinning up
  :starting |         # Service starting on instance
  :processing |       # Actively converting
  :completed |
  :failed |
  :cancelled |
  :timeout

# Map from backend responses
defp normalize_state("loading"), do: :provisioning
defp normalize_state("starting"), do: :starting
defp normalize_state("running"), do: :processing
# ...
```

---

## Response to Implementation Risks

### "Operational risk during rollout"

**Reviewer's Concern:** Feature flags at submit time; long-running jobs cross flag flips.

**Our Response:** Valid. Jobs should use the code path they were submitted with.

**Resolution:**
```elixir
# Store version in job metadata at submit time
def submit(binary, opts) do
  version = if use_v2?(), do: :v2, else: :v1

  job = Job.new(%{
    # ...
    code_version: version
  })

  # Job carries its version; await/status use same version
end

def status(job_id) do
  job = JobTracker.get(job_id)

  case job.code_version do
    :v2 -> v2_status(job)
    :v1 -> v1_status(job)
  end
end
```

### "Timeline optimism"

**Reviewer's Concern:** Five one-week phases ignore integration testing, migration rehearsal.

**Our Response:** Agreed. Revised timeline:

| Phase | Duration | Description |
|-------|----------|-------------|
| 1 | 2 weeks | Core abstractions + contracts (includes integration tests) |
| 2 | 1.5 weeks | Resilience patterns |
| 3 | 1.5 weeks | Telemetry + backends |
| 4 | 2 weeks | UI refactoring + migration rehearsal |
| 5 | 2 weeks | Gradual rollout + monitoring + cleanup |

**Total: 9 weeks** (not 5)

---

## Response to Alternative Approaches

### "Incremental hardening of v1"

**Reviewer's Suggestion:** Add behaviors/DI to existing code; circuit breaker at HTTP layer only.

**Our Response:** This is a reasonable alternative. However:

1. The current code ALREADY has behaviors (`Lumainus.Docling.Backend`) — v2 is building on this
2. Adding circuit breaker at HTTP layer alone doesn't give backend-level isolation
3. The existing test coverage uses Bypass well; we can build on this

**Compromise:** Phase 1 will be MORE incremental:
- Add CircuitBreaker wrapper to existing `HTTP.request/3`
- Add telemetry to existing code paths
- Keep existing module structure longer
- Only introduce new abstractions after telemetry proves the design

### "Persisted job registry"

**Reviewer's Suggestion:** Store job→backend in DB/ETS with WAL.

**Our Response:** Yes. The existing `IngestionJob` schema should be the source of truth. `JobTracker` GenServer is just a cache.

### "UI traceability compromise"

**Reviewer's Suggestion:** Keep user-facing simplicity but surface backend/provenance in collapsible "Details" pane.

**Our Response:** Excellent suggestion. Adopt this:

```heex
<%# User sees simple status %>
<.job_status status={@status} />

<%# Collapsible details for power users / support %>
<details class="text-xs text-slate-500">
  <summary>Processing details</summary>
  <dl>
    <dt>Backend</dt>
    <dd>{@status.backend_used}</dd>
    <dt>Endpoint</dt>
    <dd>{@status.backend_endpoint}</dd>
    <dt>Instance</dt>
    <dd>{@status.instance_id}</dd>
  </dl>
</details>
```

---

## Answers to Reviewer Questions

### Q1: How will backend provenance be stored and exposed for audits?

**A:**
- Stored in `IngestionJob.metadata` and new `JobStatus.backend_used` field
- Exposed via collapsible "Details" in UI
- Admin dashboard retains full visibility
- API responses include `_meta.backend` field

### Q2: Where is job_id -> backend mapping persisted?

**A:**
- Primary: `ingestion_jobs` table (existing)
- Cache: `JobTracker` ETS table (new, volatile)
- Recovery: On startup, rebuild cache from DB (like `InstanceManager.startup_sync`)

### Q3: Which operations are wrapped by RetryPolicy?

**A:**
- Health checks: YES
- Status polling: YES
- SSE reconnection: YES
- Convert/Enqueue: NO (circuit breaker only)

### Q4: How is Vast.ai provisioning represented in JobStatus?

**A:**
- State: `:provisioning` (new)
- Message: "Starting GPU instance..."
- Routing: BackendRouter waits for `:running` before routing to Vast.ai

### Q5: What is the plan for cross-language tracing?

**A:**
- HTTP headers: `x-trace-id`, `x-span-id`, `x-job-id`
- Python service logs with these headers
- Correlation via shared trace_id in log aggregation
- OpenTelemetry propagation (future)

### Q6: How are in-flight v1 jobs handled when feature flag flips?

**A:**
- Jobs carry `code_version` in metadata
- Status/await use the job's version
- No jobs are orphaned by flag change

---

## Revised Success Criteria

| Category | Original | Revised |
|----------|----------|---------|
| **Testability** | 100% contracts | 90%+ contracts, 80%+ coverage |
| **Observability** | All operations emit telemetry | Key operations emit telemetry; progress sampled |
| **Resilience** | Circuit breakers prevent cascade | Circuit breakers with proper error classification |
| **UI Abstraction** | Zero backend terminology | User UI abstracted; debug details available |
| **Provenance** | (not specified) | All jobs retain backend provenance |
| **Timeline** | 5 weeks | 9 weeks |

---

## Conclusion

The review identified real issues. We accept the blocking concerns and propose the following revisions:

1. **Preserve provenance** — Don't remove backend tracking; add abstraction layer on top
2. **Persist job state** — Use existing `IngestionJob` as source of truth
3. **Fix circuit breaker** — Proper error classification, bounded half-open
4. **Scope retries correctly** — Only for idempotent operations
5. **Reduce telemetry cardinality** — Backend type, not name; sample progress
6. **Extend timeline** — 9 weeks, not 5

The v2 direction is correct. The implementation details need adjustment based on this review and grounded understanding of the existing codebase.

---

## Next Steps

1. Update design documents with revisions above
2. Create detailed implementation plan for Phase 1 (incremental)
3. Set up telemetry on existing code BEFORE major refactoring
4. Prototype circuit breaker wrapper on `HTTP.request/3`
5. Review revised plan with team
