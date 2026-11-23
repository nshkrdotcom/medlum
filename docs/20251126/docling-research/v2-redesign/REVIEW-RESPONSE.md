# Docling v2 Redesign – Critical Review

## Executive Summary
Proceed only after major revision. The clean-architecture direction is sensible, but the proposal has blocking gaps around traceability, resilience semantics, observability scalability, and migration safety. Several assumptions conflict with Medlum’ “every token traceable” mandate and with operational realities (Vast.ai provisioning, long-running jobs). Timeline and rollback plans are optimistic given the surface area.

## Critical Issues (must fix before implementation)
- **Traceability regression (blocking)** – `05-ui-abstraction.md` and `06-migration-plan.md` remove user/backend provenance (only `:standard|:enhanced` plus `was_enhanced` boolean). This conflicts with auditability needs and existing document metadata that store concrete backend/capability, breaking post-incident forensics and billing attribution.
- **Orphaned/volatile job tracking (blocking)** – `01-architecture.md`’s `Service.submit/2` registers jobs before routing without transactional coupling to `BackendRouter.route/2`; no durable job→backend mapping is described. `await/3`/`cancel/1` depend on `get_job_backend/1` (not specified) and lose state on node restart, so in-flight jobs become unobservable/cancelable.
- **Circuit breaker + health + routing semantics unsafe (major)** – `02-resilience.md` treats all errors as breaker failures (including 4xx/user errors), resets to `:closed` on GenServer crash, and half-open allows unbounded concurrent probes. `select_best_backend/1` compares `{state, latency}` where atom ordering is undefined and `latency` may be `:infinity`, risking choosing degraded backends. No policy for “all backends down” beyond returning `{:error, :no_backend_available}`.
- **Retry policy may duplicate costly work (major)** – `RetryPolicy.with_retry/2` lacks idempotency guardrails; if wrapped around `enqueue/2` it will submit multiple conversions (and incur Vast.ai cost). No cancellation of in-flight retries and no guidance on which operations are safe to retry.
- **Observability cardinality and correlation gaps (major)** – `03-telemetry.md` emits tenant_id/job_id/error strings into metrics/events, which will explode Prometheus cardinality and log volume during SSE progress (per-page updates). No documented propagation of correlation/trace IDs to the Python service, so cross-language tracing is unresolved despite heavy span scaffolding.
- **Migration/data risk (major)** – `06-migration-plan.md` schedules removal of `docling_backend` and backend metadata without a preservation story for existing documents/jobs or audit trails. Rollback advice (`git checkout HEAD~1`) ignores DB state and in-flight jobs; no plan for jobs that span the feature flag switch.

## Design Concerns
- **Over-abstraction without addressing real pain** – The new layering largely rebrands what already exists (facade/backends/HTTP) while adding indirection that isn’t tied to concrete failures seen in production (e.g., Vast provisioning delays, SSE flakiness). Risk of duplicating v1 complexity under new names.
- **Domain/infrastructure leakage** – `TimeoutPolicy` and `BackendRouter` embed backend names/latency in infra while `Job` carries tenant/user metadata but no tenant-level isolation or quota policy; `ConversionPolicy.user_has_enhanced_access?/1` is a stub always returning true. Business rules for HIPAA/role-based throttling are undefined.
- **Incomplete status model** – `JobStatus.normalize_state/1` ignores states like provisioning/starting (critical for Vast.ai) and treats unknown as `:processing`, hiding stuck/backoff conditions from users and operators.
- **Health checking not bounded** – `HealthManager.perform_health_check/1` calls backend `health/0` without timeouts; periodic checks spawn unbounded processes and treat stale results as `:unknown` without coordinating with the circuit breaker or backpressure.
- **UI abstraction may hinder support** – Removing backend visibility from users and operators makes debugging user-reported latency/quality issues harder; the “Enhanced unavailable” string lacks reason/context and no operator-visible “processed by backend X at time Y” is retained.
- **Testability claims overlook shared state** – Mock backends/HTTP clients use globally named Agents; `async: true` tests will race unless names are parameterized per test. SSE/retry timing tests will be flaky without virtual time.

## Implementation Risks
- **Operational risk during rollout** – Feature flags decide at submit time, but `status/await/cancel` paths for jobs submitted on the old path are undefined once v1 code is removed (Phase 5). Long-running jobs (20m) will cross flag flips.
- **Performance regression** – New circuit breaker/health polling adds latency and background load; no sizing or benchmarking plan is provided. Finch pool sizing is speculative; cloud vs local share the same `retry`/timeout defaults despite very different RTTs.
- **Timeline optimism** – Five one-week phases ignore integration test creation, migration rehearsal, and operational dashboards. Phase 2 (resilience) and Phase 3 (telemetry) both introduce new supervision trees and background processes that typically need hardening cycles.
- **Rollback gaps** – Schema changes that drop columns cannot be safely “git checkout”-ed. No plan to keep dual writes or shadow reads to retain provenance during the cutover.

## Alternative Approaches
- **Incremental hardening of v1** – Introduce behaviors/DI into existing `Medlum.Docling` modules, add circuit breaker/retry wrappers at the HTTP layer only, and keep existing job provenance schemas intact. Avoid full namespace move until stability proves out.
- **Persisted job registry** – Store job→backend/profile/provisioning state in DB (or ETS with WAL) to survive restarts and support await/cancel across nodes; replicate via PubSub rather than in-process trackers.
- **Safer resilience defaults** – Use error classifiers to exclude 4xx/user errors from breaker counts; cap half-open probes; integrate health checks with timeouts and jittered schedules; expose breaker/health state to operators even if hidden from end users.
- **Telemetry via OpenTelemetry** – Propagate W3C trace/context headers to the Python service and emit spans through OTP’s OpenTelemetry exporter; reduce metric tags (drop tenant_id/job_id/error strings) and sample progress events.
- **UI traceability compromise** – Keep user-facing simplicity but surface backend/provenance in a collapsible “Details” pane or admin-only view; persist backend ID in document metadata even if not shown by default.

## Recommendations (priority)
- **Must fix**
  - Preserve backend provenance in storage and expose it to operators; don’t drop `docling_backend`/document backend metadata until equivalent traceability exists. (`05-ui-abstraction.md`, `06-migration-plan.md`)
  - Make job tracking durable and transactional with routing; define the authoritative job→backend mapping and how it survives restarts. (`01-architecture.md`)
  - Classify errors for circuit breaker counts; bound half-open concurrency and define behavior when all backends are down, including Vast provisioning waits. (`02-resilience.md`)
  - Define retry scope to idempotent operations only; forbid retries around `enqueue/convert` unless the backend guarantees de-duplication. (`02-resilience.md`)
  - Reduce telemetry cardinality (drop tenant_id/job_id/error strings from metrics) and specify trace propagation to Python. (`03-telemetry.md`)
- **Should fix**
  - Add timeouts to health checks and coordinate breaker/health state for routing; fix `select_best_backend/1` ordering to avoid choosing `:infinity` latencies. (`02-resilience.md`)
  - Expand `JobStatus` states to represent provisioning/starting/backoff and surface to operators; add user-level messaging that distinguishes transient vs terminal failures. (`01-architecture.md`, `05-ui-abstraction.md`)
  - Parameterize test doubles per test process; add virtual time or dependency-injected timers for retry/heartbeat tests. (`04-testing.md`)
  - Provide a migration plan for existing user preferences and document metadata, including rollback of DB state, not just code. (`06-migration-plan.md`)
- **Nice to have**
  - Consider keeping v1 and v2 side by side longer with shadow traffic to validate telemetry/latency before removal.
  - Provide operator dashboards that show backend-level detail even if user UI is abstracted.

## Questions for the Author
- How will backend provenance be stored and exposed for audits once backend names are hidden? Is there an operator UI or log guarantee?
- Where is the authoritative mapping of `job_id -> backend/profile` persisted, and how is it recovered after node restart or deploy?
- Which operations are wrapped by `RetryPolicy` and how do you prevent duplicate conversions/billing when retries fire?
- How should Vast.ai’s 3–5 minute provisioning state be represented in `JobStatus` and routing decisions?
- What is the plan for tracing across Elixir → Python → backends (headers, IDs, sampling), and how do you correlate logs today?
- How will in-flight v1 jobs be handled when the feature flag flips or v1 code is removed?
