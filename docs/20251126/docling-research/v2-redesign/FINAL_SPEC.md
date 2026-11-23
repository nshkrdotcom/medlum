• Below is a consolidated, explicit technical blueprint for the Docling v2
  foundation. It assumes greenfield implementation with no legacy support or phased
  coexistence. Emphasis: reliability, clarity, traceability, and ease of maintenance—
  not scale.

———
  
Goals & Constraints

- Reliable PDF→Markdown conversion with clear provenance and auditability.
- Simple, testable modules with behaviors and dependency injection.
- Bounded telemetry (no cardinality explosions); usable traces/logs.
- UI abstraction for end users; full detail available for operators.
- No retries around non-idempotent work; explicit resilience policies.
- Durable job→backend mapping; restart-safe.

———

Domain Model

- ProcessingProfile: :standard | :enhanced
- Job: %Job{id, profile, filename, byte_size, tenant_id, user_id, submitted_at,
  timeout_at, code_version, metadata}
    - code_version fixed at submit time for routing consistency.
- JobStatus: %JobStatus{job_id, state, progress, message, pages_total, pages_done,
  result, error, updated_at, backend_used, backend_endpoint, instance_id,
  processed_at}
    - state: :queued | :provisioning | :starting | :processing | :completed
      | :failed | :cancelled | :timeout
- Policy: file validation, size limits, profile eligibility (hooked to feature
  flags/subscription later).

———

Persistence & Provenance

- Source of truth: ingestion_jobs table (or equivalent) with columns: job_id
  (pk), profile, backend_used, backend_endpoint, instance_id, code_version, state,
  progress, tenant_id, user_id, submitted_at, updated_at, timeout_at, metadata
  (jsonb).
- Document metadata stores: processing_profile, _backend_used, _backend_endpoint,
  _instance_id, processed_at.
- In-memory cache (ETS) is optional optimization; rebuild from DB on startup.

———

Public API (Application Layer)

- submit(binary, opts) :: {:ok, Job.t()} | {:error, term()}
    - Validates file; creates Job with code_version=:v2; persists job row with
      state=:queued; routes to backend; stores chosen backend in DB.
- status(job_id) :: {:ok, JobStatus.t()} | {:error, :not_found}
    - Reads from DB; enriches with latest backend status via backend call; updates
      DB state.
- await(job_id, timeout_ms, on_progress)
    - Uses backend await/3; streams progress; updates DB; respects job’s
      code_version.
- cancel(job_id) :: :ok | {:error, term()}
- available?(profile) :: boolean() (health+breaker aware)
- profiles() :: [:standard | :enhanced] (available only)

———

Backend Abstractions (Infrastructure)

- Behavior Backend: enqueue/2, await/3, status/1, cancel/1, health/0, name/0.
- Implementations:
    - LocalBackend for cpu/gpu/docker variants (URLs from config).
    - CloudBackend for Vast.ai (reuses existing provisioning logic; treat
      provisioning as part of status/health).
- BackendRouter: map profile→backend list; choose healthy+closed breaker;
  deterministic ordering (breaker_state_priority, latency) with :infinity mapped to
  large sentinel; returns {:error, :service_unavailable} if none.

———

Resilience

- Circuit breaker per backend (Registry-backed GenServer):
    - Failure count includes only classified transient/server errors.
    - Threshold default: 5; open timeout: 30s; half-open allows 1 concurrent probe.
    - Errors counted: HTTP ≥500, 429, transport errors, timeouts. Not counted: 4xx
      (except 429), validation.
- Retry policy (exponential backoff) ONLY for idempotent ops: health checks, status
  polling, SSE reconnect. Never wrap enqueue/convert.
    - Defaults: max_attempts 3, base 1s, max 30s, jitter 20%.
- Health manager:
    - Interval: 30s jittered ±20%; timeout per check: local 10s, cloud 20s.
    - Marks stale (>90s) as :unknown.
- Timeouts:
    - Conversion timeout: min(profile default, 15m standard / 20m enhanced)
      bounded.
    - Health timeouts as above; status poll timeout 10s.
- All-backends-down: return {:error, :service_unavailable, "No processing backends
  are available"}; emit telemetry.

———

SSE / Progress

- SSE client with reconnection delays [1s, 2s, 5s, 10s, 30s], heartbeat 60s, parse
  events with JSON; terminal states stop stream.
- Progress sampling for telemetry: emit every 10th percentage point or on state
  change; still update DB on every event.

———

Telemetry, Tracing, Logging

- Metrics (low cardinality):
    - Counters: job_submitted (tags: profile, backend_type), job_completed/
      failed (profile, backend_type, error_type), circuit_opened (backend),
      retry_scheduled/exhausted.
    - Distributions: job_duration_ms (profile, backend_type), http_duration_ms
      (backend_type, method, status_bucket).
- No tenant_id/job_id/error strings in metric tags. Job IDs go to logs/traces only.
- Tracing: inject headers x-trace-id, x-span-id, x-job-id to Python; correlate logs
  via these IDs. Use OpenTelemetry exporter on Elixir side; Python logs include
  headers.
- Structured logging with context (correlation_id, trace_id, job_id, backend_used).
- Telemetry events: job lifecycle (submitted/started/progress/completed/failed/
  cancelled), circuit (opened/half_open/closed/rejected), retry (scheduled/
  succeeded/exhausted), health (checked/unhealthy/recovered), SSE (connected/
  reconnected/error/heartbeat_timeout).

———

UI & Operator Surfaces

- End-user UI: profile selector (standard/enhanced), simple status messages; no
  backend names.
- Details panel (collapsible) shows provenance: backend_used, endpoint,
  instance_id, processed_at.
- Admin/ops view: full backend health, breaker state, latency, queue depth (if
  available).

———

Routing & Versioning

- At submit: pick path code_version=:v2; store in job row.
- Status/await/cancel honor stored code_version (future-proof if another version
  appears).
- Profile→backend map (configurable):
    - standard: [:local_cpu, :local_docker_cpu]
    - enhanced: [:local_gpu, :local_docker_gpu, :cloud]
- Backend type classification for metrics: :local | :cloud.

———

Testing Approach

- Behaviors for backends and HTTP; inject mock modules.
- Mocks are per-test-process (via start_supervised + unique names) to avoid Agent
  global contention.
- Unit coverage for Policy, JobStatus normalization (including provisioning/
  starting/timeout), CircuitBreaker (property test), RetryPolicy.
- Integration tests: submit/status/await using mock backends; SSE reconnection with
  simulated drops; health/selection logic when a backend is down.
- No retries on enqueue/convert in tests; assert single submission.

———

Defaults (tunable)

- File size limit: 100 MB.
- Job timeouts: 15m standard, 20m enhanced; cap at 20m.
- Circuit breaker: threshold 5, open 30s, half-open 1 probe.
- Health check interval 30s ±20%; timeouts 10s local / 20s cloud; stale after 90s.
- Retry (idempotent ops only): max 3 attempts, base 1s, max 30s, jitter 20%.
- Progress telemetry sampling: every 10% or on state change.

———

Implementation Skeleton (Elixir names)

- lib/medlum/conversion/
    - job.ex, job_status.ex, processing_profile.ex, policy.ex
    - service.ex (public API)
    - application/job_tracker.ex (DB-backed with ETS cache)
    - infrastructure/backend_router.ex
    - infrastructure/health_manager.ex
    - infrastructure/resilience/circuit_breaker.ex
    - infrastructure/resilience/retry_policy.ex
    - infrastructure/http/client.ex (Finch/Req wrapper with trace headers)
    - infrastructure/http/sse_stream.ex
    - infrastructure/telemetry/{emitter,metrics,handler}.ex
    - infrastructure/context.ex (correlation/trace IDs)
    - backends/{local_backend,cloud_backend}.ex
    - events.ex (PubSub broadcasts without backend details)
- Tests under test/medlum/conversion/** with per-test mock modules.

———

Key Rules to Avoid Cargo-Cult Pitfalls

- Do not retry enqueue/convert; retries are idempotent-only.
- Classify errors before tripping breakers; 4xx (except 429) do not count.
- Keep provenance in storage even if UI hides it; never drop without replacement.
- Health checks are time-bounded and jittered; stale health yields :unknown not
  “healthy”.
- Progress telemetry is sampled; logs/traces carry IDs, metrics don’t.
- Cache is an optimization; DB is the truth for job→backend mapping.
- Half-open allows exactly one probe; additional calls see :open until probe
  resolves.

This blueprint is the “correct robust foundation” for v2: a clean, reliable,
auditable conversion stack with explicit behaviors, bounded resilience, lean
telemetry, and clear operator visibility while keeping the user experience simple.
