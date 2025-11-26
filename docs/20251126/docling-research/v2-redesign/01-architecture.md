# v2 Architecture: Clean Layers with Domain Boundaries

**Date:** November 26, 2025

---

## Overview

The v2 architecture follows **Clean Architecture** principles with strict layer boundaries. Each layer has a single responsibility and communicates only with adjacent layers through well-defined contracts.

---

## Layer Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           PRESENTATION                                   │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐    │
│  │ ReportsLive │  │ API.Upload  │  │ API.Jobs    │  │ Admin.      │    │
│  │ (user)      │  │ Controller  │  │ Controller  │  │ Settings    │    │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘    │
└─────────┼────────────────┼────────────────┼────────────────┼────────────┘
          │                │                │                │
          │ ConversionService.submit()      │                │
          │ ConversionService.status()      │                │
          ▼                ▼                ▼                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           APPLICATION                                    │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                     ConversionService                              │  │
│  │  - submit(binary, opts) -> {:ok, Job.t()}                         │  │
│  │  - status(job_id) -> {:ok, JobStatus.t()}                         │  │
│  │  - cancel(job_id) -> :ok                                           │  │
│  │  - available?(profile) -> boolean()                                │  │
│  │  - profiles() -> [ProcessingProfile.t()]                           │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─────────────────────┐  ┌─────────────────────┐                       │
│  │ JobTracker          │  │ ProfileResolver     │                       │
│  │ (tracks in-flight)  │  │ (user -> profile)   │                       │
│  └─────────────────────┘  └─────────────────────┘                       │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Domain types only
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                             DOMAIN                                       │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐         │
│  │ Job             │  │ JobStatus       │  │ ProcessingProfile│         │
│  │ (value object)  │  │ (value object)  │  │ (enum)           │         │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘         │
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐                               │
│  │ ConversionPolicy│  │ ProfileCapability│                              │
│  │ (business rules)│  │ (what profiles  │                               │
│  │                 │  │  can do)        │                               │
│  └─────────────────┘  └─────────────────┘                               │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Behaviors (contracts)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          INFRASTRUCTURE                                  │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                      BackendRouter                                 │  │
│  │  - Resolves profile -> backend                                     │  │
│  │  - Manages circuit breakers                                        │  │
│  │  - Handles failover                                                │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐         │
│  │ LocalBackend    │  │ CloudBackend    │  │ HealthManager   │         │
│  │ (http client)   │  │ (vast.ai)       │  │ (checks all)    │         │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘         │
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐         │
│  │ CircuitBreaker  │  │ RetryPolicy     │  │ ConnectionPool  │         │
│  │ (per backend)   │  │ (with backoff)  │  │ (Finch config)  │         │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘         │
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐                               │
│  │ TelemetryEmitter│  │ ConfigProvider  │                               │
│  │ (all events)    │  │ (from DB/env)   │                               │
│  └─────────────────┘  └─────────────────┘                               │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ HTTP, SSH, Docker API
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         EXTERNAL SERVICES                                │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐         │
│  │ Docling Service │  │ Vast.ai API     │  │ Docker Daemon   │         │
│  │ (FastAPI)       │  │                 │  │                 │         │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Module Structure

```
lib/lumainus/conversion/
├── conversion.ex                    # Public API (ConversionService)
├── job.ex                           # Job value object
├── job_status.ex                    # JobStatus value object
├── processing_profile.ex            # Profile enum
├── policy.ex                        # Business rules
│
├── application/
│   ├── service.ex                   # ConversionService implementation
│   ├── job_tracker.ex               # In-flight job tracking
│   └── profile_resolver.ex          # User -> profile mapping
│
├── infrastructure/
│   ├── backend_router.ex            # Routes to backends
│   ├── health_manager.ex            # Health check orchestration
│   ├── config_provider.ex           # Configuration abstraction
│   │
│   ├── backends/
│   │   ├── backend.ex               # Backend behavior
│   │   ├── local_backend.ex         # Local (Docker/native)
│   │   └── cloud_backend.ex         # Vast.ai
│   │
│   ├── resilience/
│   │   ├── circuit_breaker.ex       # Per-backend circuit breaker
│   │   ├── retry_policy.ex          # Exponential backoff
│   │   └── connection_pool.ex       # HTTP connection management
│   │
│   ├── http/
│   │   ├── client.ex                # HTTP client wrapper
│   │   └── sse_stream.ex            # SSE with reconnection
│   │
│   └── telemetry/
│       ├── emitter.ex               # Telemetry event emission
│       ├── metrics.ex               # Metric definitions
│       └── span.ex                  # Distributed tracing
│
└── adapters/
    ├── oban_worker.ex               # Oban job adapter
    └── pubsub_broadcaster.ex        # PubSub notifications
```

---

## Domain Layer

### Job (Value Object)

```elixir
defmodule Lumainus.Conversion.Job do
  @moduledoc """
  Represents a conversion job. Immutable value object.
  """

  @type id :: String.t()

  @type t :: %__MODULE__{
    id: id(),
    profile: ProcessingProfile.t(),
    submitted_at: DateTime.t(),
    timeout_at: DateTime.t(),
    filename: String.t(),
    byte_size: non_neg_integer(),
    tenant_id: String.t(),
    user_id: String.t(),
    metadata: map()
  }

  defstruct [
    :id,
    :profile,
    :submitted_at,
    :timeout_at,
    :filename,
    :byte_size,
    :tenant_id,
    :user_id,
    metadata: %{}
  ]

  @doc "Create a new job"
  def new(attrs) do
    %__MODULE__{
      id: attrs[:id] || generate_id(),
      profile: attrs[:profile] || :standard,
      submitted_at: DateTime.utc_now(),
      timeout_at: calculate_timeout(attrs),
      filename: attrs[:filename],
      byte_size: attrs[:byte_size],
      tenant_id: attrs[:tenant_id],
      user_id: attrs[:user_id],
      metadata: attrs[:metadata] || %{}
    }
  end

  defp generate_id, do: Ecto.UUID.generate()

  defp calculate_timeout(attrs) do
    timeout_ms = attrs[:timeout_ms] || default_timeout(attrs[:profile])
    DateTime.add(DateTime.utc_now(), timeout_ms, :millisecond)
  end

  defp default_timeout(:enhanced), do: 1_200_000  # 20 min
  defp default_timeout(_), do: 900_000            # 15 min
end
```

### JobStatus (Value Object)

```elixir
defmodule Lumainus.Conversion.JobStatus do
  @moduledoc """
  Normalized job status across all backends.
  """

  @type state :: :queued | :processing | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
    job_id: Job.id(),
    state: state(),
    progress: 0..100,
    message: String.t() | nil,
    pages_total: non_neg_integer() | nil,
    pages_done: non_neg_integer(),
    result: map() | nil,
    error: String.t() | nil,
    updated_at: DateTime.t()
  }

  defstruct [
    :job_id,
    :state,
    :result,
    :error,
    :updated_at,
    progress: 0,
    message: nil,
    pages_total: nil,
    pages_done: 0
  ]

  @doc "Create status from backend response"
  def from_backend_response(job_id, response) do
    %__MODULE__{
      job_id: job_id,
      state: normalize_state(response["state"]),
      progress: response["progress"] || 0,
      message: humanize_message(response),
      pages_total: response["pages_total"],
      pages_done: response["pages_done"] || 0,
      result: response["result"],
      error: humanize_error(response["last_error"]),
      updated_at: DateTime.utc_now()
    }
  end

  defp normalize_state("queued"), do: :queued
  defp normalize_state("pending"), do: :queued
  defp normalize_state("running"), do: :processing
  defp normalize_state("processing"), do: :processing
  defp normalize_state("completed"), do: :completed
  defp normalize_state("failed"), do: :failed
  defp normalize_state("timeout"), do: :failed
  defp normalize_state("cancelled"), do: :cancelled
  defp normalize_state(_), do: :processing

  defp humanize_message(%{"pages_done" => done, "pages_total" => total})
       when is_integer(done) and is_integer(total) do
    "Processing page #{done} of #{total}"
  end
  defp humanize_message(%{"state" => "queued"}), do: "Waiting to start"
  defp humanize_message(_), do: nil

  defp humanize_error(nil), do: nil
  defp humanize_error(error) when is_binary(error) do
    cond do
      String.contains?(error, "timeout") -> "Processing took too long"
      String.contains?(error, "memory") -> "Document too complex"
      String.contains?(error, "parse") -> "Could not read document"
      true -> "Processing failed"
    end
  end
end
```

### ProcessingProfile (Enum)

```elixir
defmodule Lumainus.Conversion.ProcessingProfile do
  @moduledoc """
  User-facing processing profiles. Hides all backend details.
  """

  @type t :: :standard | :enhanced

  @profiles [:standard, :enhanced]

  def all, do: @profiles

  def valid?(profile), do: profile in @profiles

  @doc "User-friendly label"
  def label(:standard), do: "Standard"
  def label(:enhanced), do: "Enhanced"

  @doc "Short description for UI"
  def description(:standard), do: "Free processing"
  def description(:enhanced), do: "Faster processing"

  @doc "Whether this profile may incur cost"
  def may_have_cost?(:enhanced), do: true
  def may_have_cost?(_), do: false
end
```

### ConversionPolicy (Business Rules)

```elixir
defmodule Lumainus.Conversion.Policy do
  @moduledoc """
  Business rules for conversion operations.
  """

  alias Lumainus.Conversion.{Job, ProcessingProfile}

  @max_file_size 100 * 1024 * 1024  # 100 MB
  @max_concurrent_jobs 10

  @doc "Check if user can submit with given profile"
  def can_submit?(user, profile, current_job_count) do
    cond do
      current_job_count >= @max_concurrent_jobs ->
        {:error, :too_many_jobs}

      profile == :enhanced and not user_has_enhanced_access?(user) ->
        {:error, :profile_not_available}

      true ->
        :ok
    end
  end

  @doc "Validate file for conversion"
  def validate_file(binary, filename) do
    cond do
      byte_size(binary) > @max_file_size ->
        {:error, :file_too_large}

      not String.ends_with?(String.downcase(filename), ".pdf") ->
        {:error, :invalid_file_type}

      not valid_pdf_header?(binary) ->
        {:error, :invalid_pdf}

      true ->
        :ok
    end
  end

  @doc "Get default profile for user"
  def default_profile(user) do
    if user_has_enhanced_access?(user) and user.preferences[:prefer_enhanced] do
      :enhanced
    else
      :standard
    end
  end

  defp user_has_enhanced_access?(user) do
    # Could check subscription, feature flags, etc.
    true
  end

  defp valid_pdf_header?(<<"%PDF", _::binary>>), do: true
  defp valid_pdf_header?(_), do: false
end
```

---

## Application Layer

### ConversionService

```elixir
defmodule Lumainus.Conversion.Service do
  @moduledoc """
  Main entry point for conversion operations.
  This is the ONLY module presentation layer should use.
  """

  alias Lumainus.Conversion.{Job, JobStatus, ProcessingProfile, Policy}
  alias Lumainus.Conversion.Infrastructure.BackendRouter
  alias Lumainus.Conversion.Application.JobTracker

  @type submit_opts :: [
    profile: ProcessingProfile.t(),
    filename: String.t(),
    timeout_ms: non_neg_integer(),
    on_progress: (JobStatus.t() -> any())
  ]

  @doc """
  Submit a PDF for conversion.

  ## Options
    * `:profile` - Processing profile (:standard or :enhanced). Default: user's preference.
    * `:filename` - Original filename. Required.
    * `:timeout_ms` - Custom timeout. Default: based on profile.
    * `:on_progress` - Callback for progress updates.

  ## Examples

      {:ok, job} = Service.submit(pdf_binary, filename: "report.pdf")
      {:ok, job} = Service.submit(pdf_binary, filename: "report.pdf", profile: :enhanced)
  """
  @spec submit(binary(), submit_opts()) :: {:ok, Job.t()} | {:error, term()}
  def submit(binary, opts) do
    with :ok <- Policy.validate_file(binary, opts[:filename]),
         job <- Job.new(build_job_attrs(binary, opts)),
         :ok <- JobTracker.register(job),
         {:ok, _} <- BackendRouter.route(job, binary) do
      {:ok, job}
    end
  end

  @doc """
  Get current status of a job.
  """
  @spec status(Job.id()) :: {:ok, JobStatus.t()} | {:error, :not_found}
  def status(job_id) do
    case JobTracker.get_status(job_id) do
      nil -> {:error, :not_found}
      status -> {:ok, status}
    end
  end

  @doc """
  Cancel a running job.
  """
  @spec cancel(Job.id()) :: :ok | {:error, term()}
  def cancel(job_id) do
    with {:ok, job} <- JobTracker.get(job_id),
         :ok <- BackendRouter.cancel(job) do
      JobTracker.mark_cancelled(job_id)
      :ok
    end
  end

  @doc """
  Check if a profile is currently available.
  """
  @spec available?(ProcessingProfile.t()) :: boolean()
  def available?(profile) do
    BackendRouter.profile_available?(profile)
  end

  @doc """
  Get all available profiles.
  """
  @spec profiles() :: [ProcessingProfile.t()]
  def profiles do
    ProcessingProfile.all()
    |> Enum.filter(&available?/1)
  end

  @doc """
  Wait for job completion (blocking).
  """
  @spec await(Job.id(), keyword()) :: {:ok, map()} | {:error, term()}
  def await(job_id, opts \\ []) do
    timeout = opts[:timeout_ms] || 1_200_000
    on_progress = opts[:on_progress] || fn _ -> :ok end

    BackendRouter.await(job_id, timeout, on_progress)
  end

  # Private

  defp build_job_attrs(binary, opts) do
    %{
      profile: opts[:profile] || :standard,
      filename: opts[:filename],
      byte_size: byte_size(binary),
      timeout_ms: opts[:timeout_ms],
      tenant_id: opts[:tenant_id],
      user_id: opts[:user_id],
      metadata: opts[:metadata] || %{}
    }
  end
end
```

---

## Infrastructure Layer

### Backend Behavior

```elixir
defmodule Lumainus.Conversion.Infrastructure.Backend do
  @moduledoc """
  Contract for conversion backends.
  """

  alias Lumainus.Conversion.{Job, JobStatus}

  @type convert_result :: {:ok, map()} | {:error, term()}
  @type enqueue_result :: {:ok, String.t()} | {:error, term()}

  @doc "Synchronous conversion"
  @callback convert(binary(), Job.t()) :: convert_result()

  @doc "Asynchronous conversion (returns job_id)"
  @callback enqueue(binary(), Job.t()) :: enqueue_result()

  @doc "Wait for job completion"
  @callback await(String.t(), non_neg_integer(), (JobStatus.t() -> any())) :: convert_result()

  @doc "Get job status"
  @callback status(String.t()) :: {:ok, map()} | {:error, term()}

  @doc "Cancel job"
  @callback cancel(String.t()) :: :ok | {:error, term()}

  @doc "Health check"
  @callback health() :: {:ok, map()} | {:error, term()}

  @doc "Backend identifier"
  @callback name() :: atom()

  @optional_callbacks [cancel: 1]
end
```

### BackendRouter

```elixir
defmodule Lumainus.Conversion.Infrastructure.BackendRouter do
  @moduledoc """
  Routes conversion requests to appropriate backends.
  Handles circuit breakers and failover.
  """

  alias Lumainus.Conversion.{Job, JobStatus, ProcessingProfile}
  alias Lumainus.Conversion.Infrastructure.{CircuitBreaker, HealthManager}

  @profile_backends %{
    standard: [:local_cpu, :local_docker_cpu],
    enhanced: [:local_gpu, :local_docker_gpu, :cloud]
  }

  @doc "Route job to best available backend"
  def route(%Job{profile: profile} = job, binary) do
    profile
    |> backends_for_profile()
    |> Enum.filter(&backend_available?/1)
    |> select_best_backend()
    |> case do
      nil -> {:error, :no_backend_available}
      backend -> submit_to_backend(backend, job, binary)
    end
  end

  @doc "Check if profile has available backends"
  def profile_available?(profile) do
    profile
    |> backends_for_profile()
    |> Enum.any?(&backend_available?/1)
  end

  @doc "Cancel job on backend"
  def cancel(%Job{} = job) do
    case get_job_backend(job.id) do
      nil -> {:error, :job_not_found}
      backend -> backend_module(backend).cancel(job.id)
    end
  end

  @doc "Await job completion"
  def await(job_id, timeout, on_progress) do
    case get_job_backend(job_id) do
      nil -> {:error, :job_not_found}
      backend -> backend_module(backend).await(job_id, timeout, on_progress)
    end
  end

  # Private

  defp backends_for_profile(profile) do
    Map.get(@profile_backends, profile, [])
  end

  defp backend_available?(backend) do
    CircuitBreaker.available?(backend) and HealthManager.healthy?(backend)
  end

  defp select_best_backend([]), do: nil
  defp select_best_backend(backends) do
    # Prefer: healthy > circuit open but recovering
    # Within healthy: prefer lower latency
    Enum.min_by(backends, fn backend ->
      {CircuitBreaker.state(backend), HealthManager.latency(backend)}
    end)
  end

  defp submit_to_backend(backend, job, binary) do
    CircuitBreaker.call(backend, fn ->
      backend_module(backend).enqueue(binary, job)
    end)
  end

  defp backend_module(:local_cpu), do: Lumainus.Conversion.Infrastructure.Backends.LocalBackend
  defp backend_module(:local_docker_cpu), do: Lumainus.Conversion.Infrastructure.Backends.LocalBackend
  defp backend_module(:local_gpu), do: Lumainus.Conversion.Infrastructure.Backends.LocalBackend
  defp backend_module(:local_docker_gpu), do: Lumainus.Conversion.Infrastructure.Backends.LocalBackend
  defp backend_module(:cloud), do: Lumainus.Conversion.Infrastructure.Backends.CloudBackend
end
```

---

## Dependency Injection

All infrastructure components are injected via configuration:

```elixir
# config/config.exs
config :lumainus, Lumainus.Conversion,
  # Backend implementations (can be swapped for testing)
  backend_module: Lumainus.Conversion.Infrastructure.Backends.LocalBackend,
  cloud_backend_module: Lumainus.Conversion.Infrastructure.Backends.CloudBackend,

  # HTTP client (can be mocked)
  http_client: Lumainus.Conversion.Infrastructure.Http.Client,

  # Circuit breaker config
  circuit_breaker: [
    threshold: 5,
    timeout_ms: 30_000,
    reset_timeout_ms: 60_000
  ],

  # Retry config
  retry: [
    max_attempts: 3,
    base_delay_ms: 1_000,
    max_delay_ms: 30_000
  ]

# config/test.exs
config :lumainus, Lumainus.Conversion,
  backend_module: Lumainus.Conversion.Test.MockBackend,
  http_client: Lumainus.Conversion.Test.MockHttpClient
```

---

## Key Design Decisions

### 1. No Backend Names in Domain

The domain layer has NO knowledge of:
- `docker_cpu`, `native_gpu`, `vast_ai`
- Port numbers
- URLs
- Health check details

Only `ProcessingProfile` (:standard, :enhanced) exists in the domain.

### 2. Backend Mapping is Infrastructure Concern

```elixir
# Infrastructure decides which backend serves which profile
@profile_backends %{
  standard: [:local_cpu, :local_docker_cpu],
  enhanced: [:local_gpu, :local_docker_gpu, :cloud]
}
```

This can change without affecting domain or presentation.

### 3. Status Normalization

All backend responses are normalized to `JobStatus`:

```elixir
# Backend returns: %{"state" => "running", "pages_done" => 5, ...}
# Domain sees: %JobStatus{state: :processing, progress: 50, message: "Processing page 5 of 10"}
```

User-friendly messages are derived, not passed through.

### 4. Fail-Fast at Boundaries

Validation happens at layer boundaries:
- Presentation validates user input
- Application validates business rules
- Infrastructure validates technical constraints

Each layer trusts validated data from above.

---

## Next: Resilience Patterns

See [02-resilience.md](02-resilience.md) for circuit breakers, retries, and connection management.
