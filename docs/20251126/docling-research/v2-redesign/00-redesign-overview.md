# Docling Integration v2: Ground-Up Redesign

**Date:** November 26, 2025
**Status:** Design Document
**Authors:** Architecture Team

---

## Executive Summary

This document outlines a complete rearchitecture of the Docling PDF-to-Markdown integration in Medlum. The current implementation suffers from:

1. **Zero testability** - Tightly coupled components, no dependency injection
2. **No telemetry** - Framework installed but unused, no observability
3. **Brittle connections** - No retries, no circuit breakers, hard-coded timeouts
4. **UI coupling** - Backend implementation details leak into user-facing interfaces

The v2 redesign introduces a **clean architecture** with proper separation of concerns, comprehensive observability, resilient communication patterns, and complete UI abstraction.

---

## Document Index

| Document | Description |
|----------|-------------|
| [01-architecture.md](01-architecture.md) | Clean architecture with domain boundaries |
| [02-resilience.md](02-resilience.md) | Circuit breakers, retries, connection management |
| [03-telemetry.md](03-telemetry.md) | Comprehensive observability strategy |
| [04-testing.md](04-testing.md) | Testability patterns and contracts |
| [05-ui-abstraction.md](05-ui-abstraction.md) | Complete UI decoupling |
| [06-migration-plan.md](06-migration-plan.md) | Phased migration approach |

---

## Design Goals

### 1. Testability First

Every component must be testable in isolation:

- **Behavior contracts** for all external dependencies
- **Dependency injection** via configuration, not hard-coded modules
- **Test doubles** for HTTP, GenServers, and external services
- **Property-based tests** for state machines and resilience patterns

### 2. Observable by Default

Full visibility into system behavior:

- **Telemetry events** for every significant operation
- **Distributed tracing** across job lifecycle
- **Metrics** for duration, throughput, errors, queue depth
- **Structured logging** with correlation IDs

### 3. Resilient Communication

Graceful handling of failures:

- **Circuit breakers** per backend with configurable thresholds
- **Retry with exponential backoff** for transient failures
- **Connection pooling** with proper lifecycle management
- **Health-aware routing** to available backends

### 4. UI Abstraction

Zero implementation details in user interfaces:

- **Processing profiles** instead of backend names
- **Simple status** (Ready/Processing/Error) instead of technical states
- **Performance hints** (Standard/Enhanced) not GPU/CPU terminology
- **Admin-only** infrastructure configuration

---

## Architecture Layers

```
┌─────────────────────────────────────────────────────────────┐
│                     PRESENTATION LAYER                       │
│  LiveViews, Controllers, API - NO backend knowledge          │
│  Only sees: ConversionService, ProcessingProfile, JobStatus  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     APPLICATION LAYER                        │
│  ConversionService - Orchestrates conversion workflow        │
│  Exposes: submit/2, status/1, cancel/1, health/0             │
│  Handles: Profile resolution, job tracking, callbacks        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      DOMAIN LAYER                            │
│  Core business logic - Backend agnostic                      │
│  ConversionJob, ProcessingProfile, JobStatus (value objects) │
│  ConversionPolicy - Rules for profile selection              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   INFRASTRUCTURE LAYER                       │
│  Backend implementations, HTTP clients, resilience           │
│  BackendRouter, CircuitBreaker, ConnectionPool               │
│  Telemetry emission, health checking                         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    EXTERNAL SERVICES                         │
│  Docling containers, Vast.ai API, Docker daemon              │
└─────────────────────────────────────────────────────────────┘
```

---

## Key Abstractions

### 1. ProcessingProfile (replaces "backend")

User-facing abstraction for conversion capabilities:

```elixir
defmodule Medlum.Conversion.ProcessingProfile do
  @type t :: :standard | :enhanced

  # Standard: Free, slower, always available
  # Enhanced: May cost, faster, may require provisioning
end
```

**UI shows:** "Standard" or "Enhanced" - nothing else.

### 2. ConversionService (replaces Docling facade)

Single entry point for all conversion operations:

```elixir
defmodule Medlum.Conversion.Service do
  @doc "Submit a PDF for conversion"
  @spec submit(binary(), keyword()) :: {:ok, Job.t()} | {:error, term()}

  @doc "Get job status"
  @spec status(Job.id()) :: {:ok, JobStatus.t()} | {:error, :not_found}

  @doc "Cancel a running job"
  @spec cancel(Job.id()) :: :ok | {:error, term()}

  @doc "Check if service is available"
  @spec available?(ProcessingProfile.t()) :: boolean()
end
```

### 3. JobStatus (replaces raw backend responses)

Normalized status across all backends:

```elixir
defmodule Medlum.Conversion.JobStatus do
  @type state :: :queued | :processing | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
    state: state(),
    progress: 0..100,
    message: String.t() | nil,  # User-friendly message
    result: map() | nil,        # Only on :completed
    error: String.t() | nil     # Only on :failed
  }
end
```

### 4. BackendRouter (internal only)

Routes requests to appropriate backend with resilience:

```elixir
defmodule Medlum.Conversion.Infrastructure.BackendRouter do
  @doc "Route conversion to best available backend"
  @spec route(ProcessingProfile.t(), binary(), keyword()) :: {:ok, Job.t()} | {:error, term()}

  # Internal: Handles circuit breakers, health checks, failover
end
```

---

## What Changes

### Removed from Public API

- Backend names (`docker_cpu`, `native_gpu`, `vast_ai`)
- Port numbers (8040-8044)
- Backend URLs
- Health check details
- SSE/polling implementation details
- Vast.ai-specific terminology

### Added to Public API

- `ProcessingProfile` (`:standard` or `:enhanced`)
- `JobStatus` (normalized across all backends)
- `ConversionService` (single entry point)
- Telemetry events (for observability)

### Moved to Admin-Only

- Backend configuration (URLs, timeouts)
- Circuit breaker thresholds
- Health check intervals
- Infrastructure metrics dashboard

---

## Non-Goals

This redesign does NOT:

1. Change the Python Docling service (FastAPI remains as-is)
2. Modify Docker infrastructure (ports 8040-8044 unchanged)
3. Change the Vast.ai provisioning model
4. Alter database schemas for job storage

These remain stable; only the Elixir integration layer changes.

---

## Success Criteria

### Testability
- [ ] 100% of infrastructure components have behavior contracts
- [ ] Unit tests run without network/Docker dependencies
- [ ] Integration tests use test doubles by default
- [ ] Property-based tests cover state machines

### Observability
- [ ] All operations emit telemetry events
- [ ] Metrics exported to Prometheus format
- [ ] Distributed tracing with correlation IDs
- [ ] Structured logs with request context

### Resilience
- [ ] Circuit breakers prevent cascade failures
- [ ] Retries with backoff for transient errors
- [ ] Graceful degradation when backends unavailable
- [ ] Health-aware routing to available backends

### UI Abstraction
- [ ] Zero backend terminology in user-facing UI
- [ ] ReportsLive only uses ConversionService
- [ ] Document badges show profile, not backend
- [ ] Admin UI is only place with infrastructure details

---

## Timeline Estimate

| Phase | Duration | Description |
|-------|----------|-------------|
| Phase 1 | 1 week | Core abstractions & contracts |
| Phase 2 | 1 week | Resilience patterns |
| Phase 3 | 1 week | Telemetry implementation |
| Phase 4 | 1 week | UI refactoring |
| Phase 5 | 1 week | Testing & migration |

**Total:** 5 weeks for full implementation

---

## Risk Mitigation

### Risk: Breaking existing functionality
**Mitigation:** Parallel implementation with feature flag. New code path can be enabled per-tenant.

### Risk: Performance regression
**Mitigation:** Comprehensive benchmarking before/after. Telemetry will catch regressions.

### Risk: Incomplete migration
**Mitigation:** Old code remains until 100% of traffic on new path. Clean removal only after validation.

---

## Next Steps

1. Review architecture document ([01-architecture.md](01-architecture.md))
2. Understand resilience patterns ([02-resilience.md](02-resilience.md))
3. Plan telemetry implementation ([03-telemetry.md](03-telemetry.md))
4. Design test strategy ([04-testing.md](04-testing.md))
5. Refactor UI layer ([05-ui-abstraction.md](05-ui-abstraction.md))
6. Execute migration ([06-migration-plan.md](06-migration-plan.md))
