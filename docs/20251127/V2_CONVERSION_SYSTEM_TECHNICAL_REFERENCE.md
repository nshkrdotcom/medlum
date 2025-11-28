# V2 Conversion System Technical Reference

**Document Version:** 1.0
**Last Updated:** November 27, 2025
**Status:** Production Ready
**Test Coverage:** 226 tests passing

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Architecture](#2-system-architecture)
3. [Core Modules](#3-core-modules)
4. [CloudStatus Integration](#4-cloudstatus-integration)
5. [Backend Routing](#5-backend-routing)
6. [Health Management](#6-health-management)
7. [Job Lifecycle](#7-job-lifecycle)
8. [Error Handling](#8-error-handling)
9. [Phoenix Integration](#9-phoenix-integration)
10. [Testing Strategy](#10-testing-strategy)
11. [Configuration Reference](#11-configuration-reference)
12. [Troubleshooting Guide](#12-troubleshooting-guide)
13. [Migration Notes](#13-migration-notes)

---

## 1. Executive Summary

### 1.1 Purpose

The V2 Conversion System is a complete rewrite of Lumainus's document conversion pipeline, designed to:

- Provide unified backend routing for local and cloud GPU processing
- Support on-demand cloud GPU provisioning via Vast.ai
- Maintain single source of truth for backend availability
- Enable graceful degradation and automatic failover
- Deliver clear, actionable status to end users

### 1.2 Key Design Principles

| Principle | Implementation |
|-----------|----------------|
| **Single Source of Truth** | CloudStatus module wraps InstanceManager for all cloud state |
| **Fail Fast, Recover Gracefully** | Circuit breakers prevent cascade failures |
| **User-Centric Errors** | All errors translated to actionable messages |
| **Testability** | All external dependencies injectable via options |
| **Backward Compatibility** | V1 UI patterns preserved during transition |

### 1.3 Component Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           V2 Conversion System                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                   │
│  │   Service    │───▶│BackendRouter │───▶│   Backend    │                   │
│  │   (API)      │    │  (Routing)   │    │ (Execution)  │                   │
│  └──────────────┘    └──────────────┘    └──────────────┘                   │
│         │                   │                   │                            │
│         │            ┌──────┴──────┐           │                            │
│         │            │             │           │                            │
│         ▼            ▼             ▼           ▼                            │
│  ┌──────────────┐ ┌─────────┐ ┌─────────┐ ┌──────────────┐                  │
│  │  JobTracker  │ │ Health  │ │ Cloud   │ │    HTTP      │                  │
│  │  (State)     │ │ Manager │ │ Status  │ │   Client     │                  │
│  └──────────────┘ └─────────┘ └─────────┘ └──────────────┘                  │
│                                    │                                         │
│                                    ▼                                         │
│                          ┌──────────────────┐                               │
│                          │ InstanceManager  │                               │
│                          │   (Vast.ai)      │                               │
│                          └──────────────────┘                               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. System Architecture

### 2.1 Layer Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Phoenix Layer                             │
│  ReportsLive, VastAILive, Controllers                           │
├─────────────────────────────────────────────────────────────────┤
│                        Domain Layer                              │
│  Documents.IngestionProcessor, Documents.DoclingIngestionWorker │
├─────────────────────────────────────────────────────────────────┤
│                      Conversion Layer                            │
│  Service, Job, JobStatus, ProcessingProfile, Policy             │
├─────────────────────────────────────────────────────────────────┤
│                     Infrastructure Layer                         │
│  BackendRouter, HealthManager, CircuitBreaker, HTTP.Client      │
├─────────────────────────────────────────────────────────────────┤
│                       Backend Layer                              │
│  LocalBackend, CloudBackend                                      │
├─────────────────────────────────────────────────────────────────┤
│                       External Layer                             │
│  Docling Service (HTTP), Vast.ai API, Cloudflare Tunnel         │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Data Flow

```
┌────────────────────────────────────────────────────────────────────────────┐
│                              REQUEST FLOW                                   │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  User Upload                                                                │
│      │                                                                      │
│      ▼                                                                      │
│  ReportsLive.handle_consumed_entry/3                                        │
│      │                                                                      │
│      ▼                                                                      │
│  Documents.queue_ingestion/3                                                │
│      │                                                                      │
│      ▼                                                                      │
│  Oban.insert(DoclingIngestionWorker)                                        │
│      │                                                                      │
│      ▼                                                                      │
│  DoclingIngestionWorker.perform/1                                           │
│      │                                                                      │
│      ▼                                                                      │
│  IngestionProcessor.process/1                                               │
│      │                                                                      │
│      ├──────────────────────────────────────────────────────────────┐      │
│      │                                                               │      │
│      ▼                                                               ▼      │
│  IngestionProcessor.docling_convert/1                    persist_parse/2    │
│      │                                                               │      │
│      ▼                                                               │      │
│  Conversion.Service.submit/2                                         │      │
│      │                                                               │      │
│      ├─────────────────┐                                             │      │
│      │                 │                                             │      │
│      ▼                 ▼                                             │      │
│  Policy.validate    BackendRouter.route/1                            │      │
│      │                 │                                             │      │
│      │                 ▼                                             │      │
│      │         CloudStatus.get() ◀───── InstanceManager              │      │
│      │                 │                                             │      │
│      │                 ▼                                             │      │
│      │         Backend.enqueue/2                                     │      │
│      │                 │                                             │      │
│      │    ┌────────────┼────────────┐                                │      │
│      │    │            │            │                                │      │
│      │    ▼            ▼            ▼                                │      │
│      │  Local       Docker       Cloud                               │      │
│      │  Backend     Backend      Backend                             │      │
│      │    │            │            │                                │      │
│      │    └────────────┼────────────┘                                │      │
│      │                 │                                             │      │
│      │                 ▼                                             │      │
│      │         HTTP.Client.enqueue/3                                 │      │
│      │                 │                                             │      │
│      │                 ▼                                             │      │
│      │         Docling Service                                       │      │
│      │                 │                                             │      │
│      │                 ▼                                             │      │
│      │         Service.await/2                                       │      │
│      │                 │                                             │      │
│      └─────────────────┼─────────────────────────────────────────────┘      │
│                        │                                                     │
│                        ▼                                                     │
│                   Response                                                   │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
```

### 2.3 Module Dependency Graph

```
                              ┌─────────────────┐
                              │IngestionProcessor│
                              └────────┬────────┘
                                       │
                                       ▼
                              ┌─────────────────┐
                              │Conversion.Service│
                              └────────┬────────┘
                                       │
                    ┌──────────────────┼──────────────────┐
                    │                  │                  │
                    ▼                  ▼                  ▼
             ┌──────────┐      ┌─────────────┐    ┌──────────┐
             │  Policy  │      │BackendRouter│    │JobTracker│
             └──────────┘      └──────┬──────┘    └──────────┘
                                      │
                         ┌────────────┼────────────┐
                         │            │            │
                         ▼            ▼            ▼
                  ┌───────────┐ ┌───────────┐ ┌───────────┐
                  │CloudStatus│ │HealthMgr  │ │CircuitBkr│
                  └─────┬─────┘ └───────────┘ └───────────┘
                        │
                        ▼
                ┌───────────────┐
                │InstanceManager│
                └───────────────┘
```

---

## 3. Core Modules

### 3.1 Conversion.Service

**File:** `lib/lumainus/conversion/service.ex`

The public API for document conversion. Handles job submission, status tracking, and completion awaiting.

#### Public Functions

```elixir
@spec submit(binary(), keyword()) :: {:ok, Job.t()} | {:error, term()}
@spec status(String.t(), keyword()) :: {:ok, JobStatus.t()} | {:error, :not_found}
@spec await(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
@spec cancel(String.t(), keyword()) :: :ok | {:error, term()}
@spec available?(ProcessingProfile.t(), keyword()) :: boolean()
@spec profiles(keyword()) :: [ProcessingProfile.t()]
```

#### Submit Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:filename` | `String.t()` | *required* | Original filename |
| `:profile` | `:standard \| :enhanced` | `:standard` | Processing profile |
| `:content_type` | `String.t()` | `"application/pdf"` | MIME type |
| `:user_id` | `String.t()` | `nil` | Submitting user ID |
| `:user` | `map()` | `%{}` | User map for policy checks |
| `:tenant_id` | `String.t()` | `nil` | Organization ID |
| `:timeout_ms` | `integer()` | profile default | Custom timeout |
| `:metadata` | `map()` | `%{}` | Additional metadata |

#### Usage Example

```elixir
# Submit a job
{:ok, job} = Conversion.Service.submit(pdf_binary,
  filename: "report.pdf",
  profile: :enhanced,
  user: %{cloud_processing_enabled: true},
  tenant_id: tenant.id
)

# Check status
{:ok, status} = Conversion.Service.status(job.id)

# Await with progress
{:ok, result} = Conversion.Service.await(job.id,
  timeout_ms: 300_000,
  on_progress: fn status ->
    IO.puts("Progress: #{status.progress}%")
  end
)
```

### 3.2 Conversion.Job

**File:** `lib/lumainus/conversion/job.ex`

Ecto schema representing a conversion job with full provenance tracking.

#### Schema Fields

```elixir
schema "conversion_jobs" do
  field :id, :binary_id, autogenerate: true
  field :profile, Ecto.Enum, values: [:standard, :enhanced]
  field :state, Ecto.Enum, values: [:queued, :processing, :completed, :failed, :cancelled, :timeout]
  field :filename, :string
  field :byte_size, :integer
  field :progress, :integer, default: 0
  field :pages_done, :integer
  field :pages_total, :integer

  # Provenance
  field :backend_used, Ecto.Enum, values: [:local_cpu, :local_gpu, :docker_cpu, :docker_gpu, :cloud]
  field :backend_endpoint, :string
  field :instance_id, :string

  # Timing
  field :timeout_at, :utc_datetime
  field :started_at, :utc_datetime
  field :completed_at, :utc_datetime

  # Result/Error
  field :result, :map
  field :last_error, :string

  # Ownership
  field :tenant_id, :binary_id
  field :user_id, :binary_id
  field :metadata, :map, default: %{}

  timestamps()
end
```

### 3.3 Conversion.JobStatus

**File:** `lib/lumainus/conversion/job_status.ex`

Normalized status representation for API responses and progress tracking.

```elixir
@type t :: %__MODULE__{
  job_id: String.t(),
  state: :queued | :processing | :completed | :failed | :cancelled | :timeout,
  progress: 0..100,
  pages_done: non_neg_integer() | nil,
  pages_total: non_neg_integer() | nil,
  backend: atom() | nil,
  error: String.t() | nil,
  result: map() | nil
}
```

### 3.4 Conversion.ProcessingProfile

**File:** `lib/lumainus/conversion/processing_profile.ex`

Defines processing profiles with their characteristics.

```elixir
@profiles %{
  standard: %{
    name: :standard,
    display_name: "Standard",
    timeout_ms: 300_000,      # 5 minutes
    max_file_size: 100_000_000,  # 100 MB
    backends: [:docker_cpu, :local_cpu],
    priority: :normal
  },
  enhanced: %{
    name: :enhanced,
    display_name: "Enhanced (GPU)",
    timeout_ms: 600_000,      # 10 minutes
    max_file_size: 100_000_000,
    backends: [:docker_gpu, :local_gpu, :cloud],
    priority: :high
  }
}
```

### 3.5 Conversion.Policy

**File:** `lib/lumainus/conversion/policy.ex`

Validation and authorization policies for conversion jobs.

#### Profile Access Control

```elixir
@spec user_can_access_profile?(map() | nil, ProcessingProfile.t()) :: boolean()

# :standard - Available to all users
def user_can_access_profile?(_user, :standard), do: true

# :enhanced - Requires one of:
#   - subscription: :premium
#   - feature_flags.enhanced_processing: true
#   - cloud_processing_enabled: true
def user_can_access_profile?(user, :enhanced) do
  cond do
    Map.get(user, :subscription) == :premium -> true
    user |> Map.get(:feature_flags, %{}) |> Map.get(:enhanced_processing) == true -> true
    Map.get(user, :cloud_processing_enabled, false) == true -> true
    true -> false
  end
end
```

---

## 4. CloudStatus Integration

### 4.1 Overview

CloudStatus is the **single source of truth** for cloud backend availability. It wraps the InstanceManager state machine and provides a clean, consistent API for both v1 (legacy) and v2 systems.

**File:** `lib/lumainus/conversion/cloud_status.ex`

### 4.2 Availability States

```elixir
@type availability :: :ready | :available | :provisioning | :unavailable

@type t :: %{
  availability: availability(),
  endpoint: String.t() | nil,
  message: String.t(),
  detail: String.t() | nil,
  can_accept_jobs: boolean(),
  instance_info: map() | nil
}
```

| State | `can_accept_jobs` | Meaning | User Message |
|-------|-------------------|---------|--------------|
| `:ready` | `true` | Instance running and healthy | "Cloud GPU ready" |
| `:available` | `true` | No instance, but can provision on-demand | "Cloud GPU available" |
| `:provisioning` | `true` | Instance currently starting up | "Cloud GPU provisioning" |
| `:unavailable` | `false` | Cannot accept jobs | "Cloud GPU disabled/error" |

### 4.3 State Machine Mapping

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    InstanceManager → CloudStatus Mapping                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  InstanceManager State          CloudStatus                              │
│  ─────────────────────          ───────────────                          │
│                                                                          │
│  %{status: :running,     ──▶    %{availability: :ready,                 │
│    healthy: true}                 can_accept_jobs: true,                │
│                                   endpoint: "https://..."}              │
│                                                                          │
│  %{status: :running,     ──▶    %{availability: :provisioning,          │
│    healthy: false}                can_accept_jobs: true,                │
│                                   detail: "Waiting for health check"}   │
│                                                                          │
│  %{status: :loading}     ──▶    %{availability: :provisioning,          │
│                                   can_accept_jobs: true,                │
│                                   detail: "Vast.ai instance creating"}  │
│                                                                          │
│  %{status: :none}        ──▶    if cloud_enabled?():                    │
│    (cloud enabled)                %{availability: :available,           │
│                                     can_accept_jobs: true}              │
│                                                                          │
│  %{status: :none}        ──▶    %{availability: :unavailable,           │
│    (cloud disabled)               can_accept_jobs: false}               │
│                                                                          │
│  %{status: :error,       ──▶    %{availability: :unavailable,           │
│    error: reason}                 can_accept_jobs: false,               │
│                                   detail: reason}                       │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.4 Implementation

```elixir
defmodule Lumainus.Conversion.CloudStatus do
  alias Lumainus.Docling.VastAI.InstanceManager
  alias Lumainus.Docling.Settings

  @spec get() :: t()
  def get do
    get(instance_manager: InstanceManager)
  end

  @spec get(keyword()) :: t()
  def get(opts) do
    instance_manager = Keyword.get(opts, :instance_manager, InstanceManager)

    if process_alive?(instance_manager) do
      status = get_instance_status(instance_manager)
      build_status_from_instance(status, instance_manager)
    else
      build_unavailable_status()
    end
  end

  @spec can_accept_jobs?() :: boolean()
  def can_accept_jobs?, do: get().can_accept_jobs

  @spec ready?() :: boolean()
  def ready?, do: get().availability == :ready

  @spec endpoint() :: {:ok, String.t()} | {:error, :no_endpoint}
  def endpoint do
    case get() do
      %{endpoint: endpoint} when is_binary(endpoint) and endpoint != "" ->
        {:ok, endpoint}
      _ ->
        {:error, :no_endpoint}
    end
  end
end
```

### 4.5 Usage Patterns

#### Checking Availability

```elixir
# Simple check
if CloudStatus.can_accept_jobs?() do
  # Proceed with job submission
end

# Detailed check
case CloudStatus.get() do
  %{availability: :ready, endpoint: endpoint} ->
    # Immediate processing available

  %{availability: :available} ->
    # Will provision on first use (3-5 min wait)

  %{availability: :provisioning} ->
    # Currently provisioning, job will wait

  %{availability: :unavailable, message: msg} ->
    # Cannot process, show error to user
end
```

#### In BackendRouter

```elixir
defp filter_available(backends, health_manager, circuit_breaker_fn) do
  Enum.filter(backends, fn backend ->
    case backend.backend_type do
      :cloud ->
        # Cloud uses CloudStatus instead of HealthManager
        cloud_available?()

      :local ->
        # Local backends use traditional health check
        health_ok?(backend, health_manager) and breaker_allows?(backend, circuit_breaker_fn)
    end
  end)
end

defp cloud_available? do
  case CloudStatus.get() do
    %{can_accept_jobs: true} -> true
    _ -> false
  end
end
```

---

## 5. Backend Routing

### 5.1 BackendRouter

**File:** `lib/lumainus/conversion/infrastructure/backend_router.ex`

Routes processing profiles to available backends using health status and circuit breaker state.

#### Selection Algorithm

```
1. Get backends configured for profile (from DB settings)
2. Filter by availability:
   - Cloud: CloudStatus.can_accept_jobs?
   - Local: HealthManager status (healthy or unknown)
3. Filter by circuit breaker (closed or half-open)
4. Sort by preference:
   - Breaker state priority (closed > half-open)
   - Latency (lower is better)
5. Return first available, or :service_unavailable
```

#### Routing Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        BackendRouter.route/1                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Input: :enhanced                                                        │
│                                                                          │
│      │                                                                   │
│      ▼                                                                   │
│  ┌────────────────────────────────────────────────────────────────┐     │
│  │ backends_for_profile(:enhanced)                                 │     │
│  │ Returns: [                                                      │     │
│  │   %{name: :docker_gpu, module: LocalBackend, type: :local},    │     │
│  │   %{name: :local_gpu, module: LocalBackend, type: :local},     │     │
│  │   %{name: :cloud, module: CloudBackend, type: :cloud}          │     │
│  │ ]                                                               │     │
│  └────────────────────────────────────────────────────────────────┘     │
│      │                                                                   │
│      ▼                                                                   │
│  ┌────────────────────────────────────────────────────────────────┐     │
│  │ filter_available/3                                              │     │
│  │                                                                 │     │
│  │   For :cloud backends:                                          │     │
│  │     CloudStatus.get().can_accept_jobs? ──▶ true/false          │     │
│  │                                                                 │     │
│  │   For :local backends:                                          │     │
│  │     HealthManager.status() in [:healthy, :unknown]             │     │
│  │     AND CircuitBreaker.state() in [:closed, :half_open]        │     │
│  └────────────────────────────────────────────────────────────────┘     │
│      │                                                                   │
│      ▼                                                                   │
│  ┌────────────────────────────────────────────────────────────────┐     │
│  │ sort_by_preference/3                                            │     │
│  │   Sort by: {breaker_priority, latency}                         │     │
│  │   breaker_priority: closed=0, half_open=1, open=2              │     │
│  └────────────────────────────────────────────────────────────────┘     │
│      │                                                                   │
│      ▼                                                                   │
│  ┌────────────────────────────────────────────────────────────────┐     │
│  │ select_best/1                                                   │     │
│  │   [] ──▶ {:error, :service_unavailable}                        │     │
│  │   [best | _] ──▶ {:ok, enrich_with_endpoint(best)}             │     │
│  └────────────────────────────────────────────────────────────────┘     │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Backend Info Structure

```elixir
@type backend_info :: %{
  name: atom(),           # :docker_cpu, :local_gpu, :cloud, etc.
  module: module(),       # LocalBackend or CloudBackend
  endpoint: String.t() | nil,
  backend_type: :local | :cloud
}
```

### 5.3 Profile to Backend Mapping

Configured in database via `Lumainus.Docling.Settings`:

```elixir
%{
  "standard" => ["docker_cpu", "local_cpu"],
  "enhanced" => ["docker_gpu", "local_gpu", "cloud"]
}
```

---

## 6. Health Management

### 6.1 HealthManager

**File:** `lib/lumainus/conversion/infrastructure/health_manager.ex`

Periodic health checking for **local** backends. Cloud backends are handled by CloudStatus.

#### Health States

```elixir
@type health_status :: :healthy | :unhealthy | :unknown

# :healthy  — Recent successful health check
# :unhealthy — Recent failed health check
# :unknown — No recent data (stale > 90s) or unchecked
```

#### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `check_interval_ms` | 30,000 | Interval between checks (±20% jitter) |
| `local_timeout_ms` | 10,000 | Timeout for local backend health checks |
| `cloud_timeout_ms` | 20,000 | Timeout for cloud health checks |
| `stale_threshold_ms` | 90,000 | When to consider data stale |

#### Health Check Flow

```elixir
# Cloud backends are SKIPPED - handled by CloudStatus
def handle_info({:check, backend_name}, state) do
  config = Map.get(state.backends, backend_name)

  # Skip cloud backends
  if config && config.backend_type != :cloud do
    Task.start(fn ->
      {status, latency_ms} = perform_health_check(backend_name, config)
      send(parent, {:health_result, backend_name, status, latency_ms})
    end)
  end

  {:noreply, state}
end
```

### 6.2 CircuitBreaker

**File:** `lib/lumainus/conversion/infrastructure/resilience/circuit_breaker.ex`

Prevents cascade failures by tracking backend error rates.

#### States

```
     ┌───────────────────────────────────────────────────────────────┐
     │                    Circuit Breaker States                      │
     ├───────────────────────────────────────────────────────────────┤
     │                                                                │
     │    ┌──────────┐         failure          ┌──────────┐         │
     │    │  CLOSED  │ ────────threshold────▶   │   OPEN   │         │
     │    │ (normal) │                          │ (reject) │         │
     │    └────┬─────┘                          └────┬─────┘         │
     │         │                                     │                │
     │         │                              recovery_time           │
     │      success                                  │                │
     │         │                                     ▼                │
     │         │                            ┌────────────────┐        │
     │         └─────────────────────────── │   HALF_OPEN    │        │
     │                                      │ (probe single) │        │
     │                                      └────────────────┘        │
     │                                             │                  │
     │                                     failure │ success          │
     │                                             │                  │
     │                              ┌──────────────┴──────────────┐   │
     │                              ▼                              ▼  │
     │                           OPEN                           CLOSED│
     │                                                                │
     └───────────────────────────────────────────────────────────────┘
```

---

## 7. Job Lifecycle

### 7.1 State Machine

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Job State Machine                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│                              ┌────────────┐                              │
│                              │   QUEUED   │                              │
│                              └─────┬──────┘                              │
│                                    │                                     │
│                              backend.enqueue()                           │
│                                    │                                     │
│                                    ▼                                     │
│                            ┌──────────────┐                              │
│                            │  PROCESSING  │◀────────────┐                │
│                            └───────┬──────┘             │                │
│                                    │                    │                │
│           ┌────────────────────────┼────────────────────┼────────┐       │
│           │                        │                    │        │       │
│           ▼                        ▼                    │        ▼       │
│    ┌────────────┐          ┌────────────┐         retry    ┌─────────┐  │
│    │ COMPLETED  │          │   FAILED   │───────────┘      │ TIMEOUT │  │
│    └────────────┘          └────────────┘                  └─────────┘  │
│                                                                          │
│                                    │                                     │
│                              cancel()                                    │
│                                    │                                     │
│                                    ▼                                     │
│                            ┌────────────┐                                │
│                            │ CANCELLED  │                                │
│                            └────────────┘                                │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 7.2 Cloud Backend Job Flow

With on-demand provisioning:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Cloud Backend Job Flow                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  CloudBackend.enqueue(binary, opts)                                      │
│      │                                                                   │
│      ▼                                                                   │
│  wait_for_ready(timeout_ms, opts)                                        │
│      │                                                                   │
│      ▼                                                                   │
│  CloudStatus.get()                                                       │
│      │                                                                   │
│      ├── :ready ───────────────────────────────────────▶ {:ok, endpoint} │
│      │                                                        │          │
│      ├── :available ──▶ trigger_provisioning_and_wait() ─────┐│          │
│      │                          │                             ││          │
│      │                          ▼                             ││          │
│      │                   ensure_instance()                    ││          │
│      │                          │                             ││          │
│      │                    ┌─────┴─────┐                       ││          │
│      │                    │           │                       ││          │
│      │              {:ok, endpoint}   {:error, :no_instance}  ││          │
│      │                    │                   │               ││          │
│      │                    │            (provisioning started) ││          │
│      │                    │                   │               ││          │
│      │                    │            sleep(poll_ms)         ││          │
│      │                    │                   │               ││          │
│      │                    │            loop back to           ││          │
│      │                    │            CloudStatus.get()      ││          │
│      │                    │                                   ││          │
│      ├── :provisioning ──▶ sleep(poll_ms) ────────────────────┘│          │
│      │                          │                              │          │
│      │                   loop back to CloudStatus.get()        │          │
│      │                                                         │          │
│      └── :unavailable ──▶ {:error, {:cloud_unavailable, msg}}  │          │
│                                                                │          │
│                                                                ▼          │
│                                                    HTTP.Client.enqueue() │
│                                                                │          │
│                                                                ▼          │
│                                                        Docling Service   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 7.3 Timeout Configuration

| Context | Default | Max |
|---------|---------|-----|
| Provisioning wait | 5 minutes | 10 minutes |
| Await provisioning | 1 minute | 5 minutes |
| Poll interval | 5 seconds | - |
| Standard profile job | 5 minutes | - |
| Enhanced profile job | 10 minutes | - |

---

## 8. Error Handling

### 8.1 Error Types

```elixir
# Validation Errors
{:error, :file_too_large}        # File exceeds 100MB
{:error, :invalid_content_type}  # Not a PDF
{:error, :profile_not_available} # User can't access profile

# Routing Errors
{:error, :service_unavailable}   # No backends available

# Cloud Errors
{:error, {:cloud_unavailable, message}}     # Cloud disabled or error
{:error, {:provisioning_timeout, message}}  # Provisioning took too long

# Backend Errors
{:error, :timeout}                   # Job timed out
{:error, {:failed, reason}}          # Docling processing failed
{:error, {:http_error, status, body}} # HTTP error from backend

# Job Errors
{:error, :not_found}           # Job doesn't exist
{:error, :no_instance}         # Cloud instance not available
```

### 8.2 Error Translation

In `IngestionProcessor`:

```elixir
case ConversionService.submit(binary, service_opts) do
  {:ok, job} ->
    # Continue processing

  {:error, :file_too_large} ->
    {:error, {:docling_failed, "File exceeds 100MB limit"}, job}

  {:error, :invalid_content_type} ->
    {:error, {:docling_failed, "Only PDF files are supported"}, job}

  {:error, :service_unavailable} ->
    {:error, {:docling_failed, "No conversion backends available"}, job}

  {:error, {:provisioning_timeout, message}} ->
    {:error, {:docling_failed, message}, job}

  {:error, {:cloud_unavailable, message}} ->
    {:error, {:docling_failed, "Cloud GPU unavailable: #{message}"}, job}

  {:error, reason} ->
    {:error, reason, job}
end
```

### 8.3 User-Facing Messages

| Internal Error | User Message |
|----------------|--------------|
| `:file_too_large` | "File exceeds 100MB limit" |
| `:invalid_content_type` | "Only PDF files are supported" |
| `:service_unavailable` | "No conversion backends available" |
| `:provisioning_timeout` | "Cloud GPU provisioning timed out after 5 minutes" |
| `{:cloud_unavailable, msg}` | "Cloud GPU unavailable: {msg}" |
| `:timeout` | "Processing timed out" |
| `{:docling_failed, msg}` | "{msg}" |

---

## 9. Phoenix Integration

### 9.1 ReportsLive

**File:** `lib/lumainus_web/live/reports_live.ex`

Main upload interface with cloud status display.

#### Key Functions

```elixir
# Get GPU status using CloudStatus
defp check_gpu_instance_status_fast do
  cloud_status = CloudStatus.get()

  case cloud_status do
    %{availability: :ready, endpoint: endpoint, instance_info: info} ->
      %{status: :running, endpoint: endpoint, healthy: true, cloud_status: cloud_status}

    %{availability: :provisioning, instance_info: info} ->
      %{status: :loading, healthy: false, cloud_status: cloud_status}

    %{availability: :available} ->
      %{status: :no_instance, cloud_status: cloud_status}

    %{availability: :unavailable, message: message} ->
      %{status: :unavailable, health_check_error: message, cloud_status: cloud_status}
  end
end

# Preflight check before upload
defp preflight_backend_check(socket) do
  case socket.assigns.docling_backend do
    :cloud ->
      cloud_status = CloudStatus.get()

      case cloud_status do
        %{can_accept_jobs: true} -> :ok
        %{can_accept_jobs: false, message: msg, detail: detail} ->
          {:error, "#{msg}: #{detail}"}
      end

    _ ->
      :ok
  end
end
```

#### UI States

```heex
<%!-- Cloud GPU Status Message --%>
<%= cond do %>
  <% @gpu_instance_status.cloud_status.availability == :ready -> %>
    <!-- Green: GPU Instance Running -->

  <% @gpu_instance_status.cloud_status.availability == :available -> %>
    <!-- Blue: Cloud GPU Available (will provision on first use) -->

  <% @gpu_instance_status.cloud_status.availability == :provisioning -> %>
    <!-- Amber: GPU Provisioning... -->

  <% true -> %>
    <!-- Gray: Cloud GPU Unavailable -->
<% end %>
```

### 9.2 VastAI Admin LiveView

**File:** `lib/lumainus_web/live/admin/vast_ai_live.ex`

Admin interface for Vast.ai instance management.

#### Loading State Fix

```heex
<%= cond do %>
  <% @loading -> %>
    <!-- Spinner: Checking for active instances... -->

  <% @instances == [] -> %>
    <!-- No active instances (shown AFTER load completes) -->

  <% true -> %>
    <!-- Instance cards -->
<% end %>
```

---

## 10. Testing Strategy

### 10.1 Dependency Injection

All external dependencies are injectable via options:

```elixir
# CloudBackend
CloudBackend.enqueue(binary,
  cloud_status_fn: fn -> %{availability: :ready, ...} end,
  ensure_instance_fn: fn -> {:ok, "http://..."} end,
  poll_interval_ms: 10
)

# BackendRouter
BackendRouter.route(:enhanced,
  health_manager: MockHealthManager,
  circuit_breaker_fn: fn _name -> :closed end
)

# CloudStatus
CloudStatus.get(instance_manager: MockInstanceManager)
```

### 10.2 Test Patterns

#### Mocking CloudStatus

```elixir
test "enqueues when cloud is ready" do
  bypass = Bypass.open()

  mock_cloud_status = fn ->
    %{
      availability: :ready,
      endpoint: bypass_url(bypass),
      can_accept_jobs: true,
      message: "Cloud GPU ready"
    }
  end

  result = CloudBackend.enqueue(binary,
    filename: "doc.pdf",
    cloud_status_fn: mock_cloud_status
  )

  assert {:ok, _response} = result
end
```

#### Testing Provisioning Flow

```elixir
test "waits for provisioning" do
  call_count = :counters.new(1, [:atomics])

  mock_cloud_status = fn ->
    count = :counters.get(call_count, 1)
    :counters.add(call_count, 1, 1)

    if count == 0 do
      %{availability: :available, can_accept_jobs: true}
    else
      %{availability: :ready, endpoint: "http://...", can_accept_jobs: true}
    end
  end

  mock_ensure = fn -> {:ok, "http://..."} end

  result = CloudBackend.enqueue(binary,
    cloud_status_fn: mock_cloud_status,
    ensure_instance_fn: mock_ensure,
    poll_interval_ms: 10
  )

  assert {:ok, _} = result
end
```

### 10.3 Test Files

| File | Coverage |
|------|----------|
| `test/lumainus/conversion/service_test.exs` | Service API |
| `test/lumainus/conversion/policy_test.exs` | Authorization |
| `test/lumainus/conversion/backends/cloud_backend_test.exs` | Cloud backend |
| `test/lumainus/conversion/backends/local_backend_test.exs` | Local backend |
| `test/lumainus/conversion/infrastructure/backend_router_test.exs` | Routing |
| `test/lumainus/conversion/infrastructure/health_manager_test.exs` | Health checks |

---

## 11. Configuration Reference

### 11.1 Application Config

```elixir
# config/config.exs
config :lumainus, :conversion,
  native_cpu_url: "http://localhost:8040",
  native_gpu_url: "http://localhost:8041",
  docker_cpu_url: "http://localhost:8042",
  docker_gpu_url: "http://localhost:8043",
  cloud_url: nil,  # Dynamic from InstanceManager
  debug_progress_log: false
```

### 11.2 Database Settings

Via `Lumainus.Docling.Settings`:

```elixir
%Settings{
  native_cpu_url: "http://localhost:8040",
  native_gpu_url: "http://localhost:8041",
  docker_cpu_url: "http://localhost:8042",
  docker_gpu_url: "http://localhost:8043",
  cloud_url: nil,
  v2_profile_backends: %{
    "standard" => ["docker_cpu", "local_cpu"],
    "enhanced" => ["docker_gpu", "local_gpu", "cloud"]
  }
}
```

### 11.3 Port Assignments

| Port | Backend | Type |
|------|---------|------|
| 8040 | native_cpu | Local Python, CPU |
| 8041 | native_gpu | Local Python, GPU |
| 8042 | docker_cpu | Docker, CPU |
| 8043 | docker_gpu | Docker, GPU |
| 8044 | vast_ai | Cloud (Vast.ai) |

---

## 12. Troubleshooting Guide

### 12.1 Common Issues

#### "No conversion backends available"

**Cause:** BackendRouter found no available backends for the profile.

**Debug:**
```elixir
# Check CloudStatus
iex> Lumainus.Conversion.CloudStatus.get()

# Check HealthManager
iex> Lumainus.Conversion.Infrastructure.HealthManager.status(:docker_cpu)

# Check CircuitBreaker
iex> Lumainus.Conversion.Infrastructure.Resilience.CircuitBreaker.state(:cloud)
```

**Solutions:**
1. Verify cloud is enabled in settings
2. Check InstanceManager is running
3. Verify Vast.ai API key is configured
4. Check circuit breaker isn't open

#### "Cloud GPU unavailable"

**Cause:** CloudStatus returned `:unavailable`.

**Debug:**
```elixir
iex> CloudStatus.get()
%{availability: :unavailable, message: "Cloud GPU not configured", ...}
```

**Solutions:**
1. Configure Vast.ai API key
2. Enable cloud in profile backends
3. Check InstanceManager errors

#### ":profile_not_available"

**Cause:** User doesn't have permission for `:enhanced` profile.

**Solution:** Ensure user map includes one of:
- `subscription: :premium`
- `feature_flags: %{enhanced_processing: true}`
- `cloud_processing_enabled: true`

### 12.2 Debug Commands

```elixir
# Check all backend health
for backend <- [:docker_cpu, :docker_gpu, :local_cpu, :local_gpu] do
  status = Lumainus.Conversion.Infrastructure.HealthManager.status(backend)
  IO.puts("#{backend}: #{status}")
end

# Check CloudStatus
IO.inspect(Lumainus.Conversion.CloudStatus.get(), label: "CloudStatus")

# Check InstanceManager
IO.inspect(GenServer.call(Lumainus.Docling.VastAI.InstanceManager, :status),
           label: "InstanceManager")

# Force health check
Lumainus.Conversion.Infrastructure.HealthManager.check_now(:docker_gpu)
```

---

## 13. Migration Notes

### 13.1 V1 to V2 Compatibility

The V2 system maintains compatibility with V1 patterns:

| V1 Pattern | V2 Equivalent |
|------------|---------------|
| `InstanceManager.get_status()` | `CloudStatus.get()` |
| Direct HTTP health checks | `HealthManager.status/1` |
| Manual backend selection | `BackendRouter.route/1` |

### 13.2 Breaking Changes

1. **CloudBackend no longer returns `{:ok, %{"state" => "provisioning"}}`** on no instance
   - Now waits for provisioning automatically
   - Jobs don't fail during provisioning

2. **HealthManager skips cloud backends**
   - Cloud health is now CloudStatus's responsibility
   - No more duplicate health checking

3. **BackendRouter uses CloudStatus for cloud**
   - Cloud backend available even without running instance
   - `can_accept_jobs: true` when cloud can provision

### 13.3 Upgrade Steps

1. Deploy new modules (`CloudStatus`, updated `BackendRouter`, etc.)
2. Existing jobs continue with current backends
3. New jobs use V2 routing automatically
4. Monitor for any `service_unavailable` errors
5. Verify cloud provisioning flow works end-to-end

---

## Appendix A: File Reference

| File | Purpose |
|------|---------|
| `lib/lumainus/conversion/cloud_status.ex` | Single source of truth for cloud availability |
| `lib/lumainus/conversion/service.ex` | Public API for conversion |
| `lib/lumainus/conversion/job.ex` | Job schema |
| `lib/lumainus/conversion/job_status.ex` | Status normalization |
| `lib/lumainus/conversion/processing_profile.ex` | Profile definitions |
| `lib/lumainus/conversion/policy.ex` | Validation & authorization |
| `lib/lumainus/conversion/infrastructure/backend_router.ex` | Backend routing |
| `lib/lumainus/conversion/infrastructure/health_manager.ex` | Health checking |
| `lib/lumainus/conversion/infrastructure/resilience/circuit_breaker.ex` | Circuit breaker |
| `lib/lumainus/conversion/infrastructure/http/client.ex` | HTTP client |
| `lib/lumainus/conversion/backends/local_backend.ex` | Local backend |
| `lib/lumainus/conversion/backends/cloud_backend.ex` | Cloud backend |
| `lib/lumainus/conversion/application/job_tracker.ex` | Job state tracking |
| `lib/lumainus/documents/ingestion_processor.ex` | Ingestion orchestration |
| `lib/lumainus/documents/docling_ingestion_worker.ex` | Oban worker |
| `lib/lumainus_web/live/reports_live.ex` | Upload UI |
| `lib/lumainus_web/live/admin/vast_ai_live.ex` | Admin UI |

---

## Appendix B: Glossary

| Term | Definition |
|------|------------|
| **Backend** | A Docling service endpoint (local Docker, native Python, or cloud) |
| **Profile** | Processing tier (`:standard` for CPU, `:enhanced` for GPU) |
| **CloudStatus** | Module providing unified cloud availability status |
| **InstanceManager** | GenServer managing Vast.ai GPU instances |
| **BackendRouter** | Routes profiles to available backends |
| **HealthManager** | Monitors local backend health |
| **CircuitBreaker** | Prevents cascade failures |
| **Provisioning** | Process of creating a new Vast.ai GPU instance |

---

*Document generated: November 27, 2025*
*System version: Lumainus V2 Conversion System*
