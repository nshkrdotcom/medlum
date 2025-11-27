# Docling v2 Final Specification — Expanded Implementation Guide

**Version:** 1.0
**Date:** November 26, 2025
**Author:** Claude Opus 4.5 (expanded from consolidated spec)
**Scope:** Greenfield implementation, no legacy coexistence

---

## Executive Summary

This document expands the consolidated v2 specification into actionable implementation guidance. It incorporates findings from analyzing the existing Lumainus codebase (~3,500 lines of Docling-related Elixir), mapping new abstractions to current patterns where beneficial.

**Core Principle:** Build a reliable, auditable PDF→Markdown conversion stack. Prioritize correctness and clarity over scale or premature optimization.

---

## Part 1: Domain Model

### 1.1 ProcessingProfile

```elixir
defmodule Lumainus.Conversion.ProcessingProfile do
  @moduledoc """
  User-facing processing profiles that abstract backend selection.

  - :standard — Uses local CPU backends, free tier
  - :enhanced — Uses GPU backends (local or cloud), premium tier
  """

  @type t :: :standard | :enhanced

  @profiles [:standard, :enhanced]

  def all, do: @profiles
  def valid?(profile), do: profile in @profiles

  @doc "Default timeout in milliseconds per profile"
  def default_timeout_ms(:standard), do: 900_000   # 15 minutes
  def default_timeout_ms(:enhanced), do: 1_200_000 # 20 minutes

  @doc "Maximum allowed timeout (hard cap)"
  def max_timeout_ms, do: 1_200_000 # 20 minutes absolute cap
end
```

**Mapping to existing code:**
- Current `docling_backend` field stores atoms like `:docker_cpu`, `:vast_ai`
- New `ProcessingProfile` abstracts this for users while preserving backend detail internally

### 1.2 Job

```elixir
defmodule Lumainus.Conversion.Job do
  @moduledoc """
  Represents a conversion job from submission to completion.

  ## Fields

  - `id` — UUID, primary key
  - `profile` — :standard | :enhanced
  - `filename` — Original filename for display and content-type inference
  - `byte_size` — File size in bytes
  - `tenant_id` — Organization/workspace identifier
  - `user_id` — Submitting user
  - `submitted_at` — UTC timestamp of submission
  - `timeout_at` — UTC timestamp when job should be considered timed out
  - `code_version` — :v2 (fixed at submit, enables future versioning)
  - `metadata` — JSONB for extensibility (content_type, source info, etc.)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
    id: Ecto.UUID.t(),
    profile: ProcessingProfile.t(),
    filename: String.t(),
    byte_size: non_neg_integer(),
    tenant_id: Ecto.UUID.t() | nil,
    user_id: Ecto.UUID.t() | nil,
    submitted_at: DateTime.t(),
    timeout_at: DateTime.t(),
    code_version: atom(),
    metadata: map()
  }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "conversion_jobs" do
    field :profile, Ecto.Enum, values: [:standard, :enhanced]
    field :filename, :string
    field :byte_size, :integer
    field :tenant_id, :binary_id
    field :user_id, :binary_id
    field :submitted_at, :utc_datetime_usec
    field :timeout_at, :utc_datetime_usec
    field :code_version, Ecto.Enum, values: [:v2], default: :v2
    field :metadata, :map, default: %{}

    # Backend tracking (written after routing)
    field :backend_used, Ecto.Enum,
          values: [:local_cpu, :local_gpu, :docker_cpu, :docker_gpu, :cloud]
    field :backend_endpoint, :string
    field :instance_id, :integer  # Vast.ai instance ID when applicable

    # State tracking
    field :state, Ecto.Enum,
          values: [:queued, :provisioning, :starting, :processing,
                   :completed, :failed, :cancelled, :timeout],
          default: :queued
    field :progress, :integer, default: 0
    field :pages_total, :integer
    field :pages_done, :integer, default: 0
    field :last_error, :string
    field :result, :map  # Stored on completion

    timestamps(type: :utc_datetime_usec)
  end

  def new(attrs) do
    timeout_ms = calculate_timeout(attrs)
    now = DateTime.utc_now()

    %__MODULE__{}
    |> cast(attrs, [:profile, :filename, :byte_size, :tenant_id, :user_id, :metadata])
    |> validate_required([:profile, :filename, :byte_size])
    |> put_change(:submitted_at, now)
    |> put_change(:timeout_at, DateTime.add(now, timeout_ms, :millisecond))
    |> put_change(:code_version, :v2)
    |> put_change(:state, :queued)
  end

  defp calculate_timeout(attrs) do
    profile = attrs[:profile] || :standard
    requested = attrs[:timeout_ms]
    default = ProcessingProfile.default_timeout_ms(profile)
    max = ProcessingProfile.max_timeout_ms()

    cond do
      is_nil(requested) -> default
      requested > max -> max
      true -> requested
    end
  end
end
```

**Key decisions:**
- Single table `conversion_jobs` holds both job definition and state (vs separate JobStatus table)
- `code_version` enables routing consistency and future v3 coexistence
- Backend provenance (`backend_used`, `backend_endpoint`, `instance_id`) stored directly on job

### 1.3 JobStatus (View Struct)

```elixir
defmodule Lumainus.Conversion.JobStatus do
  @moduledoc """
  Read-only view of job status, returned by status/1 and await/3.

  This is NOT persisted separately—it's constructed from Job + backend state.
  """

  @type state :: :queued | :provisioning | :starting | :processing |
                 :completed | :failed | :cancelled | :timeout

  @type t :: %__MODULE__{
    job_id: String.t(),
    state: state(),
    progress: non_neg_integer(),  # 0-100
    message: String.t() | nil,
    pages_total: non_neg_integer() | nil,
    pages_done: non_neg_integer(),
    result: map() | nil,
    error: String.t() | nil,
    updated_at: DateTime.t(),
    # Provenance (for operators, hidden from end-user UI)
    backend_used: atom(),
    backend_endpoint: String.t() | nil,
    instance_id: integer() | nil,
    processed_at: DateTime.t() | nil
  }

  defstruct [
    :job_id, :state, :progress, :message, :pages_total, :pages_done,
    :result, :error, :updated_at, :backend_used, :backend_endpoint,
    :instance_id, :processed_at
  ]

  @doc "Build JobStatus from Job record"
  def from_job(%Job{} = job) do
    %__MODULE__{
      job_id: job.id,
      state: job.state,
      progress: job.progress || 0,
      message: state_message(job.state),
      pages_total: job.pages_total,
      pages_done: job.pages_done || 0,
      result: job.result,
      error: job.last_error,
      updated_at: job.updated_at,
      backend_used: job.backend_used,
      backend_endpoint: job.backend_endpoint,
      instance_id: job.instance_id,
      processed_at: if(job.state == :completed, do: job.updated_at)
    }
  end

  @doc "Normalize backend response state to our canonical states"
  def normalize_state("queued"), do: :queued
  def normalize_state("loading"), do: :provisioning
  def normalize_state("starting"), do: :starting
  def normalize_state("running"), do: :processing
  def normalize_state("processing"), do: :processing
  def normalize_state("completed"), do: :completed
  def normalize_state("failed"), do: :failed
  def normalize_state("cancelled"), do: :cancelled
  def normalize_state("timeout"), do: :timeout
  def normalize_state(unknown) when is_binary(unknown) do
    Logger.warning("[JobStatus] Unknown state: #{unknown}, treating as :processing")
    :processing
  end

  defp state_message(:queued), do: "Waiting in queue..."
  defp state_message(:provisioning), do: "Starting GPU instance..."
  defp state_message(:starting), do: "Initializing processor..."
  defp state_message(:processing), do: "Converting document..."
  defp state_message(:completed), do: "Conversion complete"
  defp state_message(:failed), do: "Conversion failed"
  defp state_message(:cancelled), do: "Cancelled"
  defp state_message(:timeout), do: "Timed out"
end
```

**Mapping to existing code:**
- Current `InstanceManager` uses states: `:none`, `:running`, `:stopped`, `:loading`
- The `normalize_state/1` function maps backend-specific states to our canonical set
- `"loading"` from Vast.ai maps to `:provisioning`

### 1.4 Policy

```elixir
defmodule Lumainus.Conversion.Policy do
  @moduledoc """
  Validation and authorization policies for conversion jobs.

  ## Responsibilities
  - File validation (size, type)
  - Profile eligibility (feature flags, subscription)
  - Rate limiting hooks (future)
  """

  @max_file_size 100 * 1024 * 1024  # 100 MB
  @allowed_content_types ~w(application/pdf)

  @type validation_error ::
    :file_too_large |
    :invalid_content_type |
    :profile_not_available |
    :rate_limited

  @doc "Validate file before submission"
  @spec validate_file(binary(), keyword()) :: :ok | {:error, validation_error()}
  def validate_file(binary, opts) when is_binary(binary) do
    content_type = Keyword.get(opts, :content_type, "application/pdf")

    cond do
      byte_size(binary) > @max_file_size ->
        {:error, :file_too_large}

      content_type not in @allowed_content_types ->
        {:error, :invalid_content_type}

      true ->
        :ok
    end
  end

  @doc "Check if user can access a profile"
  @spec user_can_access_profile?(map(), ProcessingProfile.t()) :: boolean()
  def user_can_access_profile?(user, :standard), do: true
  def user_can_access_profile?(user, :enhanced) do
    # Hook into feature flags / subscription system
    # Current implementation: check user preferences or tenant settings
    cond do
      Map.get(user, :subscription) == :premium -> true
      Map.get(user, :feature_flags, %{}) |> Map.get(:enhanced_processing) -> true
      # Allow if cloud backend is explicitly enabled for user
      Map.get(user, :cloud_processing_enabled, false) -> true
      true -> false
    end
  end

  @doc "Get maximum file size in bytes"
  def max_file_size, do: @max_file_size

  @doc "Get allowed content types"
  def allowed_content_types, do: @allowed_content_types
end
```

---

## Part 2: Persistence & Provenance

### 2.1 Database Schema

```elixir
defmodule Lumainus.Repo.Migrations.CreateConversionJobs do
  use Ecto.Migration

  def change do
    create table(:conversion_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Job definition
      add :profile, :string, null: false
      add :filename, :string, null: false
      add :byte_size, :integer, null: false
      add :tenant_id, :binary_id
      add :user_id, :binary_id
      add :submitted_at, :utc_datetime_usec, null: false
      add :timeout_at, :utc_datetime_usec, null: false
      add :code_version, :string, null: false, default: "v2"
      add :metadata, :map, default: %{}

      # Backend provenance (written after routing)
      add :backend_used, :string
      add :backend_endpoint, :string
      add :instance_id, :integer

      # State tracking
      add :state, :string, null: false, default: "queued"
      add :progress, :integer, default: 0
      add :pages_total, :integer
      add :pages_done, :integer, default: 0
      add :last_error, :text
      add :result, :map

      timestamps(type: :utc_datetime_usec)
    end

    # Indexes for common queries
    create index(:conversion_jobs, [:tenant_id])
    create index(:conversion_jobs, [:user_id])
    create index(:conversion_jobs, [:state])
    create index(:conversion_jobs, [:submitted_at])
    create index(:conversion_jobs, [:state, :submitted_at])
  end
end
```

### 2.2 Document Metadata Storage

When storing conversion results to documents, include provenance:

```elixir
# In document creation/update
document_metadata = %{
  # User-facing
  processing_profile: job.profile,  # :standard or :enhanced

  # Provenance (prefixed with _ to indicate internal/debug)
  _backend_used: job.backend_used,
  _backend_endpoint: job.backend_endpoint,
  _instance_id: job.instance_id,
  _processed_at: DateTime.utc_now(),
  _job_id: job.id
}
```

**Mapping to existing code:**
- Current `ReportsLive` stores `docling_backend` and `docling_backend_status` in document metadata (lines ~1090-1091)
- New approach preserves this pattern with consistent naming

### 2.3 JobTracker (In-Memory Cache)

```elixir
defmodule Lumainus.Conversion.Application.JobTracker do
  @moduledoc """
  ETS-backed cache for active job lookups.

  ## Design
  - Database is source of truth
  - ETS provides fast lookups for in-flight jobs
  - Cache rebuilds from DB on startup
  - Updates are write-through (DB first, then ETS)
  """

  use GenServer
  require Logger

  alias Lumainus.Conversion.Job
  alias Lumainus.Repo

  @table :conversion_job_tracker

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a new job (write-through to DB)"
  def register(%Job{} = job) do
    GenServer.call(__MODULE__, {:register, job})
  end

  @doc "Get job by ID (ETS first, fallback to DB)"
  def get(job_id) do
    case :ets.lookup(@table, job_id) do
      [{^job_id, job}] -> {:ok, job}
      [] -> get_from_db(job_id)
    end
  end

  @doc "Update job state (write-through)"
  def update(job_id, updates) do
    GenServer.call(__MODULE__, {:update, job_id, updates})
  end

  @doc "Remove completed/failed job from cache (keeps in DB)"
  def remove_from_cache(job_id) do
    :ets.delete(@table, job_id)
    :ok
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    # Rebuild cache from DB on startup (like InstanceManager.startup_sync)
    rebuild_cache()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, job}, _from, state) do
    case Repo.insert(job) do
      {:ok, persisted_job} ->
        :ets.insert(@table, {persisted_job.id, persisted_job})
        {:reply, {:ok, persisted_job}, state}

      {:error, changeset} ->
        {:reply, {:error, changeset}, state}
    end
  end

  @impl true
  def handle_call({:update, job_id, updates}, _from, state) do
    case get(job_id) do
      {:ok, job} ->
        changeset = Job.changeset(job, updates)
        case Repo.update(changeset) do
          {:ok, updated_job} ->
            :ets.insert(@table, {job_id, updated_job})
            {:reply, {:ok, updated_job}, state}

          {:error, changeset} ->
            {:reply, {:error, changeset}, state}
        end

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # Private

  defp get_from_db(job_id) do
    case Repo.get(Job, job_id) do
      nil -> {:error, :not_found}
      job ->
        # Cache for future lookups
        :ets.insert(@table, {job_id, job})
        {:ok, job}
    end
  end

  defp rebuild_cache do
    # Load active jobs (not completed/failed/cancelled/timeout)
    import Ecto.Query

    active_states = [:queued, :provisioning, :starting, :processing]

    Job
    |> where([j], j.state in ^active_states)
    |> Repo.all()
    |> Enum.each(fn job ->
      :ets.insert(@table, {job.id, job})
    end)

    Logger.info("[JobTracker] Rebuilt cache with #{:ets.info(@table, :size)} active jobs")
  end
end
```

**Mapping to existing code:**
- Pattern mirrors `InstanceManager.handle_info(:startup_sync, ...)` (line ~814 in existing code)
- Write-through ensures DB is always consistent

---

## Part 3: Public API (Application Layer)

### 3.1 Service Module

```elixir
defmodule Lumainus.Conversion.Service do
  @moduledoc """
  Public API for document conversion.

  ## Usage

      # Submit a job
      {:ok, job} = Service.submit(pdf_binary,
        filename: "report.pdf",
        profile: :enhanced,
        user_id: user.id,
        tenant_id: tenant.id
      )

      # Check status
      {:ok, status} = Service.status(job.id)

      # Await completion with progress
      {:ok, result} = Service.await(job.id,
        timeout_ms: 300_000,
        on_progress: fn status -> IO.puts(status.progress) end
      )
  """

  alias Lumainus.Conversion.{Job, JobStatus, Policy, ProcessingProfile}
  alias Lumainus.Conversion.Application.JobTracker
  alias Lumainus.Conversion.Infrastructure.{BackendRouter, Telemetry}

  require Logger

  @doc """
  Submit a file for conversion.

  ## Options
  - `:filename` (required) — Original filename
  - `:profile` — :standard (default) or :enhanced
  - `:content_type` — MIME type (default: "application/pdf")
  - `:user_id` — Submitting user ID
  - `:tenant_id` — Organization ID
  - `:timeout_ms` — Custom timeout (capped at profile max)
  - `:metadata` — Additional metadata map

  ## Returns
  - `{:ok, Job.t()}` — Job submitted successfully
  - `{:error, :file_too_large}` — File exceeds 100MB
  - `{:error, :invalid_content_type}` — Not a PDF
  - `{:error, :profile_not_available}` — User can't access profile
  - `{:error, :service_unavailable}` — No backends available
  """
  @spec submit(binary(), keyword()) :: {:ok, Job.t()} | {:error, term()}
  def submit(binary, opts) when is_binary(binary) do
    profile = Keyword.get(opts, :profile, :standard)

    with :ok <- Policy.validate_file(binary, opts),
         :ok <- validate_profile_access(opts, profile),
         {:ok, backend} <- BackendRouter.route(profile),
         {:ok, job} <- create_and_persist_job(binary, opts, profile, backend),
         {:ok, _response} <- enqueue_to_backend(job, binary, backend) do

      Telemetry.emit_job_submitted(job)
      {:ok, job}
    end
  end

  @doc """
  Get current status of a job.

  ## Returns
  - `{:ok, JobStatus.t()}` — Current status
  - `{:error, :not_found}` — Job doesn't exist
  """
  @spec status(String.t()) :: {:ok, JobStatus.t()} | {:error, :not_found}
  def status(job_id) when is_binary(job_id) do
    with {:ok, job} <- JobTracker.get(job_id),
         {:ok, backend_status} <- fetch_backend_status(job),
         {:ok, updated_job} <- merge_and_persist_status(job, backend_status) do
      {:ok, JobStatus.from_job(updated_job)}
    end
  end

  @doc """
  Await job completion with progress callbacks.

  ## Options
  - `:timeout_ms` — Override timeout (default: job's timeout_at)
  - `:on_progress` — Function called on each progress update

  ## Returns
  - `{:ok, result}` — Conversion result map
  - `{:error, :timeout}` — Job timed out
  - `{:error, :not_found}` — Job doesn't exist
  - `{:error, {:failed, reason}}` — Conversion failed
  """
  @spec await(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def await(job_id, opts \\ []) when is_binary(job_id) do
    with {:ok, job} <- JobTracker.get(job_id) do
      backend_module = backend_module_for(job.backend_used)
      on_progress = Keyword.get(opts, :on_progress, fn _ -> :ok end)

      # Calculate remaining timeout
      timeout_ms = remaining_timeout(job, opts)

      wrapped_progress = fn backend_status ->
        # Update DB and emit telemetry
        normalized = JobStatus.normalize_state(backend_status["state"])
        JobTracker.update(job_id, %{
          state: normalized,
          progress: backend_status["progress"],
          pages_done: backend_status["pages_done"],
          pages_total: backend_status["pages_total"]
        })

        status = JobStatus.from_job(Map.merge(job, %{
          state: normalized,
          progress: backend_status["progress"]
        }))

        Telemetry.emit_job_progress(job, status.progress)
        on_progress.(status)
      end

      case backend_module.await(job_to_backend_job(job), timeout_ms: timeout_ms, on_status: wrapped_progress) do
        {:ok, result} ->
          JobTracker.update(job_id, %{state: :completed, result: result})
          Telemetry.emit_job_completed(job)
          {:ok, result}

        {:error, :timeout} ->
          JobTracker.update(job_id, %{state: :timeout})
          Telemetry.emit_job_failed(job, :timeout)
          {:error, :timeout}

        {:error, {:docling_failed, reason}} ->
          JobTracker.update(job_id, %{state: :failed, last_error: inspect(reason)})
          Telemetry.emit_job_failed(job, :docling_failed)
          {:error, {:failed, reason}}

        {:error, reason} ->
          JobTracker.update(job_id, %{state: :failed, last_error: inspect(reason)})
          Telemetry.emit_job_failed(job, :unknown)
          {:error, reason}
      end
    end
  end

  @doc """
  Cancel a running job.
  """
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(job_id) when is_binary(job_id) do
    with {:ok, job} <- JobTracker.get(job_id),
         :ok <- backend_module_for(job.backend_used).cancel(job_id) do
      JobTracker.update(job_id, %{state: :cancelled})
      Telemetry.emit_job_cancelled(job)
      :ok
    end
  end

  @doc """
  Check if a profile is currently available (backends healthy, breakers closed).
  """
  @spec available?(ProcessingProfile.t()) :: boolean()
  def available?(profile) do
    case BackendRouter.route(profile) do
      {:ok, _backend} -> true
      {:error, _} -> false
    end
  end

  @doc """
  List currently available profiles.
  """
  @spec profiles() :: [ProcessingProfile.t()]
  def profiles do
    ProcessingProfile.all()
    |> Enum.filter(&available?/1)
  end

  # Private helpers

  defp validate_profile_access(opts, profile) do
    user = Keyword.get(opts, :user, %{})
    if Policy.user_can_access_profile?(user, profile) do
      :ok
    else
      {:error, :profile_not_available}
    end
  end

  defp create_and_persist_job(binary, opts, profile, backend) do
    job_attrs = %{
      profile: profile,
      filename: Keyword.fetch!(opts, :filename),
      byte_size: byte_size(binary),
      tenant_id: Keyword.get(opts, :tenant_id),
      user_id: Keyword.get(opts, :user_id),
      timeout_ms: Keyword.get(opts, :timeout_ms),
      metadata: Keyword.get(opts, :metadata, %{}),
      backend_used: backend.name,
      backend_endpoint: backend.endpoint
    }

    job_attrs
    |> Job.new()
    |> JobTracker.register()
  end

  defp enqueue_to_backend(job, binary, backend) do
    # NO RETRY HERE — enqueue is not idempotent
    backend.module.enqueue(binary, [
      filename: job.filename,
      job_id: job.id,
      timeout_ms: DateTime.diff(job.timeout_at, DateTime.utc_now(), :millisecond)
    ])
  end

  defp fetch_backend_status(job) do
    backend_module = backend_module_for(job.backend_used)
    backend_module.status(job.id)
  end

  defp merge_and_persist_status(job, backend_status) do
    updates = %{
      state: JobStatus.normalize_state(backend_status["state"]),
      progress: backend_status["progress"],
      pages_done: backend_status["pages_done"],
      pages_total: backend_status["pages_total"]
    }
    JobTracker.update(job.id, updates)
  end

  defp remaining_timeout(job, opts) do
    case Keyword.get(opts, :timeout_ms) do
      nil ->
        max(0, DateTime.diff(job.timeout_at, DateTime.utc_now(), :millisecond))
      override ->
        min(override, DateTime.diff(job.timeout_at, DateTime.utc_now(), :millisecond))
    end
  end

  defp backend_module_for(:local_cpu), do: Lumainus.Conversion.Backends.LocalBackend
  defp backend_module_for(:local_gpu), do: Lumainus.Conversion.Backends.LocalBackend
  defp backend_module_for(:docker_cpu), do: Lumainus.Conversion.Backends.LocalBackend
  defp backend_module_for(:docker_gpu), do: Lumainus.Conversion.Backends.LocalBackend
  defp backend_module_for(:cloud), do: Lumainus.Conversion.Backends.CloudBackend

  defp job_to_backend_job(job) do
    %{
      job_id: job.id,
      timeout_ms: DateTime.diff(job.timeout_at, DateTime.utc_now(), :millisecond),
      backend: backend_module_for(job.backend_used),
      metadata: %{
        endpoint: job.backend_endpoint,
        instance_id: job.instance_id
      }
    }
  end
end
```

**Critical design decisions:**
1. `enqueue_to_backend/3` has NO retry wrapper — this is intentional per spec
2. Status updates are write-through to DB
3. Progress callbacks receive `JobStatus` structs, not raw backend responses
4. Timeout calculation respects job's original `timeout_at`

---

## Part 4: Backend Abstractions

### 4.1 Backend Behavior

```elixir
defmodule Lumainus.Conversion.Backend do
  @moduledoc """
  Behavior for conversion backends.

  Each backend must implement these callbacks. The module is responsible
  for its own HTTP communication, health tracking, and error handling.
  """

  @type job_ref :: %{
    job_id: String.t(),
    timeout_ms: non_neg_integer(),
    backend: module(),
    metadata: map()
  }

  @type enqueue_result :: {:ok, map()} | {:error, term()}
  @type status_result :: {:ok, map()} | {:error, term()}
  @type await_result :: {:ok, map()} | {:error, term()}
  @type health_result :: {:ok, map()} | {:error, term()}

  @doc "Enqueue a file for async conversion. Returns job reference."
  @callback enqueue(binary :: binary(), opts :: keyword()) :: enqueue_result()

  @doc "Await job completion with progress callbacks."
  @callback await(job_ref(), opts :: keyword()) :: await_result()

  @doc "Get job status without blocking."
  @callback status(job_id :: String.t()) :: status_result()

  @doc "Cancel a running job."
  @callback cancel(job_id :: String.t()) :: :ok | {:error, term()}

  @doc "Check backend health."
  @callback health() :: health_result()

  @doc "Return backend name atom."
  @callback name() :: atom()

  @doc "Return backend type for metrics."
  @callback backend_type() :: :local | :cloud
end
```

**Mapping to existing code:**
- Current `Lumainus.Docling.Backend` behavior (152 lines) has similar callbacks
- Added explicit `backend_type/0` for metric tagging

### 4.2 LocalBackend

```elixir
defmodule Lumainus.Conversion.Backends.LocalBackend do
  @moduledoc """
  Backend for local CPU/GPU instances (native or Docker).

  Delegates HTTP operations to shared client module.
  """

  @behaviour Lumainus.Conversion.Backend

  alias Lumainus.Conversion.Infrastructure.HTTP.Client
  alias Lumainus.Conversion.Infrastructure.Context

  @impl true
  def enqueue(binary, opts) do
    endpoint = get_endpoint(opts)
    Client.enqueue(binary, opts, base_url: endpoint)
  end

  @impl true
  def await(job_ref, opts) do
    endpoint = job_ref.metadata.endpoint
    Client.await(job_ref, opts, base_url: endpoint)
  end

  @impl true
  def status(job_id) do
    endpoint = get_endpoint_for_job(job_id)
    Client.job_status(job_id, base_url: endpoint)
  end

  @impl true
  def cancel(job_id) do
    endpoint = get_endpoint_for_job(job_id)
    Client.cancel(job_id, base_url: endpoint)
  end

  @impl true
  def health do
    endpoint = get_active_endpoint()
    Client.health(base_url: endpoint, timeout_ms: 10_000)
  end

  @impl true
  def name, do: get_backend_name()

  @impl true
  def backend_type, do: :local

  # Private

  defp get_endpoint(opts) do
    Keyword.get(opts, :endpoint) || get_active_endpoint()
  end

  defp get_active_endpoint do
    # Read from config/settings
    config = Application.get_env(:lumainus, :conversion, [])
    backend = config[:active_local_backend] || :docker_cpu

    case backend do
      :native_cpu -> config[:native_cpu_url] || "http://localhost:8040"
      :native_gpu -> config[:native_gpu_url] || "http://localhost:8041"
      :docker_cpu -> config[:docker_cpu_url] || "http://localhost:8042"
      :docker_gpu -> config[:docker_gpu_url] || "http://localhost:8043"
    end
  end

  defp get_backend_name do
    config = Application.get_env(:lumainus, :conversion, [])
    config[:active_local_backend] || :docker_cpu
  end

  defp get_endpoint_for_job(job_id) do
    # Look up from JobTracker
    case Lumainus.Conversion.Application.JobTracker.get(job_id) do
      {:ok, job} -> job.backend_endpoint
      _ -> get_active_endpoint()
    end
  end
end
```

### 4.3 CloudBackend

```elixir
defmodule Lumainus.Conversion.Backends.CloudBackend do
  @moduledoc """
  Backend for Vast.ai cloud GPU instances.

  Handles automatic instance provisioning via InstanceManager.
  Provisioning state is surfaced through health/status.
  """

  @behaviour Lumainus.Conversion.Backend

  alias Lumainus.Conversion.Infrastructure.HTTP.Client
  alias Lumainus.Docling.VastAI.InstanceManager  # Reuse existing
  alias Lumainus.Docling.VastAI.ActivityTracker

  require Logger

  @impl true
  def enqueue(binary, opts) do
    with {:ok, endpoint} <- ensure_instance() do
      record_activity()
      Client.enqueue(binary, opts, base_url: endpoint)
    end
  end

  @impl true
  def await(job_ref, opts) do
    endpoint = job_ref.metadata.endpoint
    result = Client.await(job_ref, opts, base_url: endpoint)
    record_activity()
    result
  end

  @impl true
  def status(job_id) do
    case get_endpoint() do
      {:ok, endpoint} -> Client.job_status(job_id, base_url: endpoint)
      {:error, :no_instance} -> {:ok, %{"state" => "provisioning"}}
    end
  end

  @impl true
  def cancel(job_id) do
    case get_endpoint() do
      {:ok, endpoint} -> Client.cancel(job_id, base_url: endpoint)
      {:error, :no_instance} -> {:error, :no_instance}
    end
  end

  @impl true
  def health do
    case InstanceManager.get_endpoint() do
      {:ok, endpoint} ->
        Client.health(base_url: endpoint, timeout_ms: 20_000)

      {:error, :no_instance} ->
        # Check if provisioning is in progress
        case InstanceManager.status() do
          :loading -> {:ok, %{"status" => "provisioning"}}
          :none -> {:error, :no_instance}
          _ -> {:error, :no_instance}
        end
    end
  end

  @impl true
  def name, do: :cloud

  @impl true
  def backend_type, do: :cloud

  # Private

  defp ensure_instance do
    case InstanceManager.ensure_instance() do
      {:ok, endpoint} -> {:ok, endpoint}
      {:error, reason} ->
        # Try fallback to configured cloud_url
        case get_configured_cloud_url() do
          url when is_binary(url) and url != "" -> {:ok, url}
          _ -> {:error, reason}
        end
    end
  end

  defp get_endpoint do
    InstanceManager.get_endpoint()
  end

  defp get_configured_cloud_url do
    Application.get_env(:lumainus, :conversion, [])[:cloud_url]
  end

  defp record_activity do
    InstanceManager.update_activity()
    ActivityTracker.record_activity()
  end
end
```

**Mapping to existing code:**
- Reuses existing `InstanceManager` (1,377 lines) for provisioning
- Pattern matches current `Lumainus.Docling.Backends.VastAI` fallback logic

### 4.4 BackendRouter

```elixir
defmodule Lumainus.Conversion.Infrastructure.BackendRouter do
  @moduledoc """
  Routes processing profiles to available backends.

  ## Selection Algorithm
  1. Get backends configured for profile
  2. Filter by health (healthy or unknown, not unhealthy)
  3. Filter by circuit breaker (closed or half-open, not open)
  4. Sort by: breaker state priority, then latency
  5. Return first available, or :service_unavailable

  ## Backend Ordering
  - Closed breaker: priority 0
  - Half-open breaker: priority 1
  - Open breaker: filtered out

  Latency ties broken by config order.
  """

  alias Lumainus.Conversion.Infrastructure.{HealthManager, CircuitBreaker}

  require Logger

  @type backend_info :: %{
    name: atom(),
    module: module(),
    endpoint: String.t(),
    backend_type: :local | :cloud
  }

  @doc """
  Route a profile to the best available backend.

  Returns `{:ok, backend_info}` or `{:error, :service_unavailable}`.
  """
  @spec route(ProcessingProfile.t()) :: {:ok, backend_info()} | {:error, :service_unavailable}
  def route(profile) do
    profile
    |> backends_for_profile()
    |> filter_available()
    |> sort_by_preference()
    |> select_best()
  end

  @doc """
  Get all backends configured for a profile.
  """
  def backends_for_profile(:standard) do
    config = Application.get_env(:lumainus, :conversion, [])

    [
      %{name: :local_cpu, module: LocalBackend,
        endpoint: config[:native_cpu_url] || "http://localhost:8040",
        backend_type: :local},
      %{name: :docker_cpu, module: LocalBackend,
        endpoint: config[:docker_cpu_url] || "http://localhost:8042",
        backend_type: :local}
    ]
  end

  def backends_for_profile(:enhanced) do
    config = Application.get_env(:lumainus, :conversion, [])

    [
      %{name: :local_gpu, module: LocalBackend,
        endpoint: config[:native_gpu_url] || "http://localhost:8041",
        backend_type: :local},
      %{name: :docker_gpu, module: LocalBackend,
        endpoint: config[:docker_gpu_url] || "http://localhost:8043",
        backend_type: :local},
      %{name: :cloud, module: CloudBackend,
        endpoint: config[:cloud_url],
        backend_type: :cloud}
    ]
  end

  # Private

  defp filter_available(backends) do
    Enum.filter(backends, fn backend ->
      health_ok?(backend) and breaker_allows?(backend)
    end)
  end

  defp health_ok?(backend) do
    case HealthManager.status(backend.name) do
      :healthy -> true
      :unknown -> true  # Give benefit of doubt
      :unhealthy -> false
    end
  end

  defp breaker_allows?(backend) do
    case CircuitBreaker.state(backend.name) do
      :closed -> true
      :half_open -> true  # Allow probe
      :open -> false
    end
  end

  defp sort_by_preference(backends) do
    Enum.sort_by(backends, fn backend ->
      breaker_priority = breaker_state_priority(backend.name)
      latency = HealthManager.latency(backend.name)
      latency_value = normalize_latency(latency)

      {breaker_priority, latency_value}
    end)
  end

  defp breaker_state_priority(backend_name) do
    case CircuitBreaker.state(backend_name) do
      :closed -> 0
      :half_open -> 1
      :open -> 2  # Should be filtered out, but just in case
    end
  end

  defp normalize_latency(:infinity), do: 999_999_999
  defp normalize_latency(nil), do: 999_999_999
  defp normalize_latency(ms) when is_integer(ms), do: ms

  defp select_best([]), do: {:error, :service_unavailable}
  defp select_best([best | _]), do: {:ok, best}
end
```

---

## Part 5: Resilience Patterns

### 5.1 Circuit Breaker

```elixir
defmodule Lumainus.Conversion.Infrastructure.Resilience.CircuitBreaker do
  @moduledoc """
  Per-backend circuit breaker using Registry-backed GenServer.

  ## States
  - :closed — Normal operation, requests pass through
  - :open — Failing, reject immediately
  - :half_open — Testing recovery, allow ONE probe

  ## Error Classification
  Failures that trip the breaker:
  - HTTP 5xx errors
  - HTTP 429 (rate limited)
  - Transport errors (connection refused, timeout)
  - Request timeouts

  NOT counted as failures:
  - HTTP 4xx (except 429) — client errors
  - Validation errors
  - Successful responses

  ## Configuration
  - failure_threshold: 5 (default)
  - open_timeout_ms: 30_000 (default)
  - half_open_max_probes: 1 (always)
  """

  use GenServer
  require Logger

  @failure_threshold 5
  @open_timeout_ms 30_000
  @half_open_max_probes 1

  @type state :: :closed | :open | :half_open

  defstruct [
    :backend_name,
    state: :closed,
    failure_count: 0,
    last_failure_at: nil,
    open_until: nil,
    half_open_probes: 0
  ]

  # Client API

  def start_link(backend_name) do
    GenServer.start_link(__MODULE__, backend_name, name: via(backend_name))
  end

  @doc "Get current breaker state"
  @spec state(atom()) :: state()
  def state(backend_name) do
    case GenServer.whereis(via(backend_name)) do
      nil -> :closed  # No breaker = closed
      pid -> GenServer.call(pid, :state)
    end
  end

  @doc "Execute function through breaker"
  @spec call(atom(), (-> result)) :: result | {:error, :circuit_open} when result: term()
  def call(backend_name, fun) do
    case GenServer.whereis(via(backend_name)) do
      nil -> fun.()  # No breaker registered
      pid -> GenServer.call(pid, {:call, fun})
    end
  end

  @doc "Record a successful call"
  def record_success(backend_name) do
    case GenServer.whereis(via(backend_name)) do
      nil -> :ok
      pid -> GenServer.cast(pid, :success)
    end
  end

  @doc "Record a failure (only if it should count)"
  def record_failure(backend_name, error) do
    if should_count_as_failure?(error) do
      case GenServer.whereis(via(backend_name)) do
        nil -> :ok
        pid -> GenServer.cast(pid, {:failure, error})
      end
    end
  end

  # Server Callbacks

  @impl true
  def init(backend_name) do
    {:ok, %__MODULE__{backend_name: backend_name}}
  end

  @impl true
  def handle_call(:state, _from, state) do
    current = evaluate_state(state)
    {:reply, current, state}
  end

  @impl true
  def handle_call({:call, fun}, _from, state) do
    case evaluate_state(state) do
      :open ->
        Telemetry.emit_circuit_rejected(state.backend_name)
        {:reply, {:error, :circuit_open}, state}

      :half_open when state.half_open_probes >= @half_open_max_probes ->
        # Already have a probe in flight
        {:reply, {:error, :circuit_open}, state}

      :half_open ->
        # Allow probe
        new_state = %{state | half_open_probes: state.half_open_probes + 1}
        result = execute_and_record(fun, state.backend_name)
        {:reply, result, new_state}

      :closed ->
        result = execute_and_record(fun, state.backend_name)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_cast(:success, state) do
    new_state = case evaluate_state(state) do
      :half_open ->
        # Probe succeeded, close the circuit
        Logger.info("[CircuitBreaker] #{state.backend_name} recovered, closing circuit")
        Telemetry.emit_circuit_closed(state.backend_name)
        %{state | state: :closed, failure_count: 0, half_open_probes: 0, open_until: nil}

      _ ->
        # Reset failure count on success
        %{state | failure_count: 0}
    end
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:failure, error}, state) do
    new_count = state.failure_count + 1
    now = System.monotonic_time(:millisecond)

    new_state = cond do
      evaluate_state(state) == :half_open ->
        # Probe failed, reopen
        Logger.warning("[CircuitBreaker] #{state.backend_name} probe failed, reopening")
        Telemetry.emit_circuit_opened(state.backend_name)
        %{state |
          state: :open,
          failure_count: new_count,
          last_failure_at: now,
          open_until: now + @open_timeout_ms,
          half_open_probes: 0
        }

      new_count >= @failure_threshold ->
        Logger.warning("[CircuitBreaker] #{state.backend_name} threshold reached (#{new_count}), opening")
        Telemetry.emit_circuit_opened(state.backend_name)
        %{state |
          state: :open,
          failure_count: new_count,
          last_failure_at: now,
          open_until: now + @open_timeout_ms
        }

      true ->
        %{state | failure_count: new_count, last_failure_at: now}
    end

    {:noreply, new_state}
  end

  # Private

  defp via(backend_name) do
    {:via, Registry, {Lumainus.Conversion.Registry, {:circuit_breaker, backend_name}}}
  end

  defp evaluate_state(%{state: :open, open_until: open_until}) do
    now = System.monotonic_time(:millisecond)
    if now >= open_until do
      :half_open
    else
      :open
    end
  end
  defp evaluate_state(%{state: state}), do: state

  defp execute_and_record(fun, backend_name) do
    try do
      result = fun.()
      record_success(backend_name)
      result
    rescue
      e ->
        record_failure(backend_name, e)
        reraise e, __STACKTRACE__
    catch
      :exit, reason ->
        record_failure(backend_name, {:exit, reason})
        exit(reason)
    end
  end

  @doc "Classify errors for breaker counting"
  def should_count_as_failure?({:http_error, status, _}) when status >= 500, do: true
  def should_count_as_failure?({:http_error, 429, _}), do: true  # Rate limited
  def should_count_as_failure?({:http_error, _, _}), do: false   # Other 4xx
  def should_count_as_failure?({:transport_error, _}), do: true
  def should_count_as_failure?(:timeout), do: true
  def should_count_as_failure?(%Req.TransportError{}), do: true
  def should_count_as_failure?(_), do: false
end
```

### 5.2 Retry Policy

```elixir
defmodule Lumainus.Conversion.Infrastructure.Resilience.RetryPolicy do
  @moduledoc """
  Retry policy with exponential backoff.

  ## CRITICAL: Only for Idempotent Operations

  This policy should ONLY wrap:
  - Health checks
  - Status polling
  - SSE reconnection attempts

  NEVER wrap:
  - enqueue/2 (creates duplicate jobs)
  - convert/2 (processes file twice)

  ## Configuration
  - max_attempts: 3 (default)
  - base_delay_ms: 1000 (default)
  - max_delay_ms: 30_000 (default)
  - jitter_percent: 20 (default)
  """

  require Logger

  @default_max_attempts 3
  @default_base_delay_ms 1_000
  @default_max_delay_ms 30_000
  @default_jitter_percent 20

  @type opts :: [
    max_attempts: pos_integer(),
    base_delay_ms: pos_integer(),
    max_delay_ms: pos_integer(),
    jitter_percent: non_neg_integer(),
    on_retry: (attempt :: pos_integer(), delay :: pos_integer(), error :: term() -> any())
  ]

  @doc """
  Execute function with retry policy.

  ## Options
  - `:max_attempts` — Maximum attempts including first try (default: 3)
  - `:base_delay_ms` — Initial delay between retries (default: 1000)
  - `:max_delay_ms` — Maximum delay cap (default: 30000)
  - `:jitter_percent` — Random jitter percentage (default: 20)
  - `:on_retry` — Callback on each retry attempt
  """
  @spec with_retry((-> result), opts()) :: result when result: term()
  def with_retry(fun, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
    execute(fun, 1, max_attempts, opts)
  end

  defp execute(fun, attempt, max_attempts, opts) do
    case fun.() do
      {:ok, _} = success ->
        success

      {:error, reason} = error when attempt < max_attempts ->
        if retryable_error?(reason) do
          delay = calculate_delay(attempt, opts)

          on_retry = Keyword.get(opts, :on_retry, fn _, _, _ -> :ok end)
          on_retry.(attempt, delay, reason)

          Telemetry.emit_retry_scheduled(attempt, delay, reason)
          Logger.debug("[RetryPolicy] Attempt #{attempt} failed, retrying in #{delay}ms: #{inspect(reason)}")

          Process.sleep(delay)
          execute(fun, attempt + 1, max_attempts, opts)
        else
          error
        end

      {:error, _} = error ->
        Telemetry.emit_retry_exhausted(attempt, error)
        error

      other ->
        other
    end
  end

  defp calculate_delay(attempt, opts) do
    base = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    max = Keyword.get(opts, :max_delay_ms, @default_max_delay_ms)
    jitter_pct = Keyword.get(opts, :jitter_percent, @default_jitter_percent)

    # Exponential: base * 2^(attempt-1)
    exponential = base * :math.pow(2, attempt - 1) |> trunc()
    capped = min(exponential, max)

    # Add jitter
    jitter_range = capped * jitter_pct / 100 |> trunc()
    jitter = if jitter_range > 0, do: :rand.uniform(jitter_range * 2) - jitter_range, else: 0

    max(0, capped + jitter)
  end

  defp retryable_error?({:transport_error, _}), do: true
  defp retryable_error?(:timeout), do: true
  defp retryable_error?({:http_error, status, _}) when status >= 500, do: true
  defp retryable_error?({:http_error, 429, _}), do: true
  defp retryable_error?(_), do: false
end
```

### 5.3 Health Manager

```elixir
defmodule Lumainus.Conversion.Infrastructure.HealthManager do
  @moduledoc """
  Periodic health checking for all backends.

  ## Health States
  - :healthy — Recent successful health check
  - :unhealthy — Recent failed health check
  - :unknown — No recent data (stale > 90s)

  ## Configuration
  - check_interval_ms: 30_000 ±20% jitter
  - local_timeout_ms: 10_000
  - cloud_timeout_ms: 20_000
  - stale_threshold_ms: 90_000
  """

  use GenServer
  require Logger

  alias Lumainus.Conversion.Infrastructure.Resilience.RetryPolicy

  @check_interval_ms 30_000
  @local_timeout_ms 10_000
  @cloud_timeout_ms 20_000
  @stale_threshold_ms 90_000
  @jitter_percent 20

  defstruct [:backends, :health_states]

  # Client API

  def start_link(opts \\ []) do
    backends = Keyword.get(opts, :backends, default_backends())
    GenServer.start_link(__MODULE__, backends, name: __MODULE__)
  end

  @doc "Get health status for a backend"
  @spec status(atom()) :: :healthy | :unhealthy | :unknown
  def status(backend_name) do
    GenServer.call(__MODULE__, {:status, backend_name})
  end

  @doc "Get latency for a backend (ms or :infinity)"
  @spec latency(atom()) :: non_neg_integer() | :infinity
  def latency(backend_name) do
    GenServer.call(__MODULE__, {:latency, backend_name})
  end

  @doc "Force immediate health check"
  def check_now(backend_name) do
    GenServer.cast(__MODULE__, {:check_now, backend_name})
  end

  # Server Callbacks

  @impl true
  def init(backends) do
    state = %__MODULE__{
      backends: backends,
      health_states: %{}
    }

    # Schedule initial checks with staggered starts
    Enum.each(backends, fn {name, _config} ->
      delay = :rand.uniform(5_000)  # Stagger 0-5s
      Process.send_after(self(), {:check, name}, delay)
    end)

    {:ok, state}
  end

  @impl true
  def handle_call({:status, backend_name}, _from, state) do
    result = case Map.get(state.health_states, backend_name) do
      nil -> :unknown
      %{status: status, checked_at: checked_at} ->
        if stale?(checked_at), do: :unknown, else: status
    end
    {:reply, result, state}
  end

  @impl true
  def handle_call({:latency, backend_name}, _from, state) do
    result = case Map.get(state.health_states, backend_name) do
      nil -> :infinity
      %{latency_ms: latency} -> latency || :infinity
    end
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:check_now, backend_name}, state) do
    send(self(), {:check, backend_name})
    {:noreply, state}
  end

  @impl true
  def handle_info({:check, backend_name}, state) do
    config = state.backends[backend_name]

    if config do
      # Run health check with retry (health checks are idempotent)
      {status, latency_ms} = perform_health_check(backend_name, config)

      new_health = %{
        status: status,
        latency_ms: latency_ms,
        checked_at: System.monotonic_time(:millisecond)
      }

      new_states = Map.put(state.health_states, backend_name, new_health)

      # Emit telemetry
      case status do
        :healthy ->
          Telemetry.emit_health_checked(backend_name, latency_ms)
        :unhealthy ->
          Telemetry.emit_health_unhealthy(backend_name)
      end

      # Schedule next check with jitter
      schedule_next_check(backend_name)

      {:noreply, %{state | health_states: new_states}}
    else
      {:noreply, state}
    end
  end

  # Private

  defp perform_health_check(backend_name, config) do
    timeout = health_timeout(config.backend_type)
    start = System.monotonic_time(:millisecond)

    result = RetryPolicy.with_retry(
      fn -> config.module.health() end,
      max_attempts: 2,  # Quick retries for health
      base_delay_ms: 500
    )

    elapsed = System.monotonic_time(:millisecond) - start

    case result do
      {:ok, _} -> {:healthy, elapsed}
      {:error, _} -> {:unhealthy, nil}
    end
  end

  defp health_timeout(:local), do: @local_timeout_ms
  defp health_timeout(:cloud), do: @cloud_timeout_ms

  defp stale?(checked_at) do
    now = System.monotonic_time(:millisecond)
    now - checked_at > @stale_threshold_ms
  end

  defp schedule_next_check(backend_name) do
    jitter = trunc(@check_interval_ms * @jitter_percent / 100)
    delay = @check_interval_ms + :rand.uniform(jitter * 2) - jitter
    Process.send_after(self(), {:check, backend_name}, delay)
  end

  defp default_backends do
    %{
      local_cpu: %{module: LocalBackend, backend_type: :local},
      docker_cpu: %{module: LocalBackend, backend_type: :local},
      local_gpu: %{module: LocalBackend, backend_type: :local},
      docker_gpu: %{module: LocalBackend, backend_type: :local},
      cloud: %{module: CloudBackend, backend_type: :cloud}
    }
  end
end
```

---

## Part 6: SSE & Progress Streaming

### 6.1 SSE Stream

```elixir
defmodule Lumainus.Conversion.Infrastructure.HTTP.SSEStream do
  @moduledoc """
  Server-Sent Events client with automatic reconnection.

  ## Features
  - Exponential backoff reconnection: [1s, 2s, 5s, 10s, 30s]
  - Heartbeat monitoring (60s timeout)
  - JSON event parsing
  - Terminal state detection (completed/failed)

  ## Usage

      {:ok, pid} = SSEStream.subscribe(job_id,
        base_url: "http://localhost:8042",
        timeout_ms: 300_000,
        on_event: fn event -> handle(event) end
      )
  """

  use GenServer
  require Logger

  @reconnect_delays [1_000, 2_000, 5_000, 10_000, 30_000]
  @heartbeat_timeout_ms 60_000

  defstruct [
    :job_id,
    :base_url,
    :timeout_ms,
    :on_event,
    :caller,
    :conn,
    :reconnect_index,
    :heartbeat_ref
  ]

  # Client API

  def subscribe(job_id, opts) do
    GenServer.start_link(__MODULE__, {job_id, opts, self()})
  end

  def cancel(pid) do
    GenServer.stop(pid, :normal)
  end

  # Server Callbacks

  @impl true
  def init({job_id, opts, caller}) do
    state = %__MODULE__{
      job_id: job_id,
      base_url: Keyword.fetch!(opts, :base_url),
      timeout_ms: Keyword.get(opts, :timeout_ms, 300_000),
      on_event: Keyword.get(opts, :on_event, fn _ -> :ok end),
      caller: caller,
      reconnect_index: 0
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    url = "#{state.base_url}/jobs/#{state.job_id}/events"

    case start_sse_connection(url) do
      {:ok, conn} ->
        Logger.debug("[SSEStream] Connected to #{url}")
        Telemetry.emit_sse_connected(state.job_id)
        heartbeat_ref = schedule_heartbeat_check()
        {:noreply, %{state | conn: conn, reconnect_index: 0, heartbeat_ref: heartbeat_ref}}

      {:error, reason} ->
        Logger.warning("[SSEStream] Connection failed: #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  @impl true
  def handle_info({:sse_data, data}, state) do
    # Reset heartbeat on any data
    cancel_heartbeat(state.heartbeat_ref)
    heartbeat_ref = schedule_heartbeat_check()

    case parse_sse_event(data) do
      {:ok, event} ->
        state.on_event.(event)
        send(state.caller, {:sse_event, state.job_id, event})

        if terminal_state?(event) do
          send(state.caller, {:sse_done, state.job_id, terminal_result(event)})
          {:stop, :normal, state}
        else
          {:noreply, %{state | heartbeat_ref: heartbeat_ref}}
        end

      {:error, _reason} ->
        {:noreply, %{state | heartbeat_ref: heartbeat_ref}}
    end
  end

  @impl true
  def handle_info(:heartbeat_timeout, state) do
    Logger.warning("[SSEStream] Heartbeat timeout for job #{state.job_id}")
    Telemetry.emit_sse_heartbeat_timeout(state.job_id)
    close_connection(state.conn)
    send(self(), :connect)
    {:noreply, %{state | conn: nil}}
  end

  @impl true
  def handle_info({:sse_error, reason}, state) do
    Logger.warning("[SSEStream] Error: #{inspect(reason)}")
    Telemetry.emit_sse_error(state.job_id, reason)
    close_connection(state.conn)
    schedule_reconnect(state)
  end

  @impl true
  def handle_info({:sse_closed, _reason}, state) do
    schedule_reconnect(state)
  end

  # Private

  defp start_sse_connection(url) do
    # Use Finch for streaming
    request = Finch.build(:get, url, [{"accept", "text/event-stream"}])

    parent = self()

    Task.start_link(fn ->
      Finch.stream(request, Lumainus.Finch, nil, fn
        {:status, status}, _acc when status in 200..299 ->
          nil

        {:status, status}, _acc ->
          send(parent, {:sse_error, {:http_error, status}})
          nil

        {:headers, _headers}, acc ->
          acc

        {:data, data}, acc ->
          send(parent, {:sse_data, data})
          acc
      end)
    end)
  end

  defp schedule_reconnect(state) do
    delay = Enum.at(@reconnect_delays, state.reconnect_index, List.last(@reconnect_delays))
    new_index = min(state.reconnect_index + 1, length(@reconnect_delays) - 1)

    Logger.debug("[SSEStream] Reconnecting in #{delay}ms (attempt #{new_index + 1})")
    Telemetry.emit_sse_reconnecting(state.job_id, delay)

    Process.send_after(self(), :connect, delay)
    {:noreply, %{state | reconnect_index: new_index, conn: nil}}
  end

  defp schedule_heartbeat_check do
    Process.send_after(self(), :heartbeat_timeout, @heartbeat_timeout_ms)
  end

  defp cancel_heartbeat(nil), do: :ok
  defp cancel_heartbeat(ref), do: Process.cancel_timer(ref)

  defp close_connection(nil), do: :ok
  defp close_connection(conn), do: :ok  # Finch handles cleanup

  defp parse_sse_event(data) do
    # Parse SSE format: "data: {...}\n\n"
    case Regex.run(~r/data:\s*(.+)/s, data) do
      [_, json] ->
        case Jason.decode(String.trim(json)) do
          {:ok, parsed} -> {:ok, parsed}
          error -> error
        end
      _ ->
        {:error, :invalid_sse_format}
    end
  end

  defp terminal_state?(%{"state" => "completed"}), do: true
  defp terminal_state?(%{"state" => "failed"}), do: true
  defp terminal_state?(%{"state" => "cancelled"}), do: true
  defp terminal_state?(_), do: false

  defp terminal_result(%{"state" => "completed"}), do: :completed
  defp terminal_result(%{"state" => "failed"}), do: :failed
  defp terminal_result(%{"state" => "cancelled"}), do: :cancelled
end
```

**Mapping to existing code:**
- Current `SSEConsumer` (166 lines) lacks reconnection
- New `SSEStream` adds exponential backoff reconnection and heartbeat monitoring

---

## Part 7: Telemetry & Observability

### 7.1 Telemetry Emitter

```elixir
defmodule Lumainus.Conversion.Infrastructure.Telemetry.Emitter do
  @moduledoc """
  Telemetry event emission.

  ## Cardinality Rules
  - Metrics use bounded tags only: profile, backend_type, error_type, status_bucket
  - NO tenant_id, job_id, or error strings in metrics
  - Job IDs go to logs and traces only
  - Progress telemetry is sampled (every 10%)
  """

  @progress_sample_rate 10

  # Job Lifecycle

  def emit_job_submitted(job) do
    :telemetry.execute(
      [:lumainus, :conversion, :job, :submitted],
      %{count: 1},
      %{profile: job.profile, backend_type: backend_type(job.backend_used)}
    )
  end

  def emit_job_completed(job) do
    duration = DateTime.diff(DateTime.utc_now(), job.submitted_at, :millisecond)

    :telemetry.execute(
      [:lumainus, :conversion, :job, :completed],
      %{count: 1, duration_ms: duration},
      %{profile: job.profile, backend_type: backend_type(job.backend_used)}
    )
  end

  def emit_job_failed(job, error_type) do
    :telemetry.execute(
      [:lumainus, :conversion, :job, :failed],
      %{count: 1},
      %{
        profile: job.profile,
        backend_type: backend_type(job.backend_used),
        error_type: normalize_error_type(error_type)
      }
    )
  end

  def emit_job_cancelled(job) do
    :telemetry.execute(
      [:lumainus, :conversion, :job, :cancelled],
      %{count: 1},
      %{profile: job.profile, backend_type: backend_type(job.backend_used)}
    )
  end

  def emit_job_progress(job, progress) do
    # Sample: only emit every 10%
    if rem(progress, @progress_sample_rate) == 0 do
      :telemetry.execute(
        [:lumainus, :conversion, :job, :progress],
        %{progress: progress},
        %{profile: job.profile, backend_type: backend_type(job.backend_used)}
      )
    end
  end

  # Circuit Breaker

  def emit_circuit_opened(backend_name) do
    :telemetry.execute(
      [:lumainus, :conversion, :circuit, :opened],
      %{count: 1},
      %{backend: backend_name}
    )
  end

  def emit_circuit_closed(backend_name) do
    :telemetry.execute(
      [:lumainus, :conversion, :circuit, :closed],
      %{count: 1},
      %{backend: backend_name}
    )
  end

  def emit_circuit_rejected(backend_name) do
    :telemetry.execute(
      [:lumainus, :conversion, :circuit, :rejected],
      %{count: 1},
      %{backend: backend_name}
    )
  end

  # Retry

  def emit_retry_scheduled(attempt, delay_ms, _reason) do
    :telemetry.execute(
      [:lumainus, :conversion, :retry, :scheduled],
      %{count: 1, delay_ms: delay_ms},
      %{attempt: attempt}
    )
  end

  def emit_retry_exhausted(attempts, _error) do
    :telemetry.execute(
      [:lumainus, :conversion, :retry, :exhausted],
      %{count: 1},
      %{attempts: attempts}
    )
  end

  # Health

  def emit_health_checked(backend_name, latency_ms) do
    :telemetry.execute(
      [:lumainus, :conversion, :health, :checked],
      %{latency_ms: latency_ms},
      %{backend: backend_name}
    )
  end

  def emit_health_unhealthy(backend_name) do
    :telemetry.execute(
      [:lumainus, :conversion, :health, :unhealthy],
      %{count: 1},
      %{backend: backend_name}
    )
  end

  # SSE

  def emit_sse_connected(job_id) do
    :telemetry.execute(
      [:lumainus, :conversion, :sse, :connected],
      %{count: 1},
      %{}  # No job_id in metrics
    )
  end

  def emit_sse_reconnecting(job_id, delay_ms) do
    :telemetry.execute(
      [:lumainus, :conversion, :sse, :reconnecting],
      %{count: 1, delay_ms: delay_ms},
      %{}
    )
  end

  def emit_sse_error(job_id, _reason) do
    :telemetry.execute(
      [:lumainus, :conversion, :sse, :error],
      %{count: 1},
      %{}
    )
  end

  def emit_sse_heartbeat_timeout(job_id) do
    :telemetry.execute(
      [:lumainus, :conversion, :sse, :heartbeat_timeout],
      %{count: 1},
      %{}
    )
  end

  # HTTP

  def emit_http_request(method, status, duration_ms, backend_type) do
    :telemetry.execute(
      [:lumainus, :conversion, :http, :request],
      %{duration_ms: duration_ms},
      %{
        method: method,
        status_bucket: status_bucket(status),
        backend_type: backend_type
      }
    )
  end

  # Private

  defp backend_type(:local_cpu), do: :local
  defp backend_type(:local_gpu), do: :local
  defp backend_type(:docker_cpu), do: :local
  defp backend_type(:docker_gpu), do: :local
  defp backend_type(:cloud), do: :cloud
  defp backend_type(_), do: :unknown

  defp status_bucket(status) when status in 200..299, do: "2xx"
  defp status_bucket(status) when status in 400..499, do: "4xx"
  defp status_bucket(status) when status in 500..599, do: "5xx"
  defp status_bucket(_), do: "other"

  defp normalize_error_type(:timeout), do: :timeout
  defp normalize_error_type(:docling_failed), do: :docling_failed
  defp normalize_error_type({:transport_error, _}), do: :transport_error
  defp normalize_error_type({:http_error, status, _}) when status >= 500, do: :server_error
  defp normalize_error_type(_), do: :unknown
end
```

### 7.2 Trace Context

```elixir
defmodule Lumainus.Conversion.Infrastructure.Context do
  @moduledoc """
  Request context for correlation and tracing.

  Stores trace_id, span_id, and correlation_id in process dictionary
  for easy access throughout a request lifecycle.
  """

  @context_key :lumainus_conversion_context

  defstruct [:trace_id, :span_id, :correlation_id, :job_id, :tenant_id, :user_id]

  @doc "Initialize context for a new request"
  def init(opts \\ []) do
    ctx = %__MODULE__{
      trace_id: Keyword.get(opts, :trace_id, generate_id()),
      span_id: Keyword.get(opts, :span_id, generate_id()),
      correlation_id: Keyword.get(opts, :correlation_id, generate_id()),
      job_id: Keyword.get(opts, :job_id),
      tenant_id: Keyword.get(opts, :tenant_id),
      user_id: Keyword.get(opts, :user_id)
    }
    Process.put(@context_key, ctx)
    ctx
  end

  @doc "Get current context"
  def get do
    Process.get(@context_key) || %__MODULE__{}
  end

  @doc "Update context fields"
  def put(updates) when is_map(updates) do
    ctx = Map.merge(get(), updates)
    Process.put(@context_key, ctx)
    ctx
  end

  @doc "Build HTTP headers for trace propagation to Python"
  def to_headers do
    ctx = get()
    [
      {"x-trace-id", ctx.trace_id || ""},
      {"x-span-id", ctx.span_id || ""},
      {"x-correlation-id", ctx.correlation_id || ""},
      {"x-job-id", ctx.job_id || ""}
    ]
    |> Enum.reject(fn {_, v} -> v == "" end)
  end

  @doc "Build Logger metadata"
  def to_logger_metadata do
    ctx = get()
    [
      trace_id: ctx.trace_id,
      span_id: ctx.span_id,
      correlation_id: ctx.correlation_id,
      job_id: ctx.job_id,
      tenant_id: ctx.tenant_id,
      user_id: ctx.user_id
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
```

---

## Part 8: HTTP Client

```elixir
defmodule Lumainus.Conversion.Infrastructure.HTTP.Client do
  @moduledoc """
  HTTP client wrapper with trace header injection.

  Wraps Req library, adds context headers, emits telemetry.
  Does NOT implement retry (caller's responsibility for idempotent ops).
  """

  alias Lumainus.Conversion.Infrastructure.{Context, Telemetry}
  require Logger

  @default_timeout 15_000

  def enqueue(binary, opts, http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)

    fields = build_multipart_fields(binary, opts)

    request(:post, "#{base_url}/jobs",
      form_multipart: fields,
      receive_timeout: Keyword.get(opts, :timeout_ms, 60_000)
    )
  end

  def await(job_ref, opts, http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    timeout_ms = Keyword.get(opts, :timeout_ms, job_ref.timeout_ms)
    on_status = Keyword.get(opts, :on_status, fn _ -> :ok end)
    poll_ms = Keyword.get(opts, :poll_interval_ms, 250)

    deadline = System.monotonic_time(:millisecond) + timeout_ms

    # Try SSE first, fall back to polling
    case await_sse(job_ref.job_id, base_url, deadline, on_status) do
      {:ok, result} -> {:ok, result}
      {:fallback, _} -> poll_status(job_ref.job_id, base_url, deadline, poll_ms, on_status)
      {:error, _} = error -> error
    end
  end

  def job_status(job_id, http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    request(:get, "#{base_url}/jobs/#{job_id}/status", receive_timeout: @default_timeout)
  end

  def health(http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    timeout = Keyword.get(http_opts, :timeout_ms, 10_000)
    request(:get, "#{base_url}/health", receive_timeout: timeout)
  end

  def cancel(job_id, http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    case request(:delete, "#{base_url}/jobs/#{job_id}", receive_timeout: @default_timeout) do
      {:ok, _} -> :ok
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Private

  defp request(method, url, opts) do
    start = System.monotonic_time(:millisecond)
    headers = Context.to_headers()

    result = Req.request([method: method, url: url, headers: headers, retry: false] ++ opts)

    duration = System.monotonic_time(:millisecond) - start

    case result do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        Telemetry.emit_http_request(method, status, duration, :unknown)
        {:ok, decode_body(resp.body)}

      {:ok, %{status: status, body: body}} ->
        Telemetry.emit_http_request(method, status, duration, :unknown)
        {:error, {:http_error, status, decode_body(body)}}

      {:error, %Req.TransportError{reason: reason}} ->
        Telemetry.emit_http_request(method, 0, duration, :unknown)
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        Telemetry.emit_http_request(method, 0, duration, :unknown)
        {:error, reason}
    end
  end

  defp build_multipart_fields(binary, opts) do
    filename = Keyword.fetch!(opts, :filename)
    content_type = Keyword.get(opts, :content_type, "application/pdf")

    fields = [
      {:file, {binary, filename: filename, content_type: content_type}},
      {:output_markdown, "true"},
      {:wait, "false"}
    ]

    if job_id = Keyword.get(opts, :job_id) do
      [{:job_id, job_id} | fields]
    else
      fields
    end
  end

  defp decode_body(%{} = body), do: body
  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"raw" => body}
    end
  end
  defp decode_body(body), do: %{"raw" => inspect(body)}

  defp await_sse(job_id, base_url, deadline, on_status) do
    # Delegate to SSEStream
    timeout = max(0, deadline - System.monotonic_time(:millisecond))

    {:ok, pid} = SSEStream.subscribe(job_id,
      base_url: base_url,
      timeout_ms: timeout,
      on_event: fn event ->
        on_status.(sse_event_to_status(event))
      end
    )

    receive_sse_result(job_id, pid, base_url, deadline)
  end

  defp receive_sse_result(job_id, pid, base_url, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:sse_done, ^job_id, :completed} ->
        SSEStream.cancel(pid)
        fetch_final_result(job_id, base_url)

      {:sse_done, ^job_id, :failed} ->
        SSEStream.cancel(pid)
        {:error, {:docling_failed, nil}}

      {:sse_event, ^job_id, _event} ->
        receive_sse_result(job_id, pid, base_url, deadline)

      {:sse_error, ^job_id, reason} ->
        SSEStream.cancel(pid)
        {:fallback, reason}
    after
      remaining ->
        SSEStream.cancel(pid)
        {:error, :timeout}
    end
  end

  defp fetch_final_result(job_id, base_url) do
    case job_status(job_id, base_url: base_url) do
      {:ok, %{"state" => "completed", "result" => result}} when not is_nil(result) ->
        {:ok, result}
      {:ok, %{"state" => "completed"} = body} ->
        {:ok, Map.get(body, "result") || Map.get(body, "payload") || %{}}
      {:ok, body} ->
        {:error, {:unexpected_state, body}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp poll_status(job_id, base_url, deadline, poll_ms, on_status) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case job_status(job_id, base_url: base_url) do
        {:ok, %{"state" => "completed"} = body} ->
          on_status.(body)
          {:ok, Map.get(body, "result") || %{}}

        {:ok, %{"state" => "failed"} = body} ->
          on_status.(body)
          {:error, {:docling_failed, body["last_error"]}}

        {:ok, pending} ->
          on_status.(pending)
          Process.sleep(poll_ms)
          poll_status(job_id, base_url, deadline, poll_ms, on_status)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp sse_event_to_status(event) do
    %{
      "state" => Map.get(event, "state", "running"),
      "progress" => Map.get(event, "progress"),
      "pages_done" => Map.get(event, "pages_done"),
      "pages_total" => Map.get(event, "pages_total")
    }
  end
end
```

---

## Part 9: UI Components

### 9.1 End-User Status Display

```heex
<%!-- Simple status for end users --%>
<div class="conversion-status">
  <.status_indicator state={@status.state} />

  <%= if @status.state == :processing do %>
    <.progress_bar progress={@status.progress} />
  <% end %>

  <p class="status-message"><%= @status.message %></p>
</div>

<%!-- Collapsible details for power users / support --%>
<details class="text-xs text-slate-500 mt-2">
  <summary class="cursor-pointer hover:text-slate-700">Processing details</summary>
  <dl class="mt-1 space-y-1 pl-4">
    <div class="flex gap-2">
      <dt class="font-medium">Backend:</dt>
      <dd><%= format_backend(@status.backend_used) %></dd>
    </div>
    <%= if @status.backend_endpoint do %>
      <div class="flex gap-2">
        <dt class="font-medium">Endpoint:</dt>
        <dd class="font-mono text-xs"><%= @status.backend_endpoint %></dd>
      </div>
    <% end %>
    <%= if @status.instance_id do %>
      <div class="flex gap-2">
        <dt class="font-medium">Instance:</dt>
        <dd><%= @status.instance_id %></dd>
      </div>
    <% end %>
    <%= if @status.processed_at do %>
      <div class="flex gap-2">
        <dt class="font-medium">Processed:</dt>
        <dd><%= format_datetime(@status.processed_at) %></dd>
      </div>
    <% end %>
  </dl>
</details>
```

### 9.2 Profile Selector

```heex
<div class="profile-selector">
  <label class="block text-sm font-medium text-gray-700">Processing Mode</label>
  <div class="mt-2 space-y-2">
    <label class="flex items-center gap-3 p-3 border rounded-lg cursor-pointer hover:bg-gray-50"
           phx-click="select_profile" phx-value-profile="standard">
      <input type="radio" name="profile" value="standard"
             checked={@selected_profile == :standard} class="h-4 w-4" />
      <div>
        <span class="font-medium">Standard</span>
        <p class="text-sm text-gray-500">CPU processing, included in your plan</p>
      </div>
    </label>

    <%= if :enhanced in @available_profiles do %>
      <label class="flex items-center gap-3 p-3 border rounded-lg cursor-pointer hover:bg-gray-50"
             phx-click="select_profile" phx-value-profile="enhanced">
        <input type="radio" name="profile" value="enhanced"
               checked={@selected_profile == :enhanced} class="h-4 w-4" />
        <div>
          <span class="font-medium">Enhanced</span>
          <p class="text-sm text-gray-500">GPU processing, faster results</p>
        </div>
      </label>
    <% else %>
      <div class="flex items-center gap-3 p-3 border rounded-lg bg-gray-50 opacity-50">
        <input type="radio" disabled class="h-4 w-4" />
        <div>
          <span class="font-medium">Enhanced</span>
          <p class="text-sm text-gray-500">GPU processing (not available)</p>
        </div>
      </div>
    <% end %>
  </div>
</div>
```

---

## Part 10: Configuration Defaults

```elixir
# config/config.exs

config :lumainus, :conversion,
  # File limits
  max_file_size_bytes: 100 * 1024 * 1024,  # 100 MB

  # Backend URLs (ports per existing standard)
  native_cpu_url: "http://localhost:8040",
  native_gpu_url: "http://localhost:8041",
  docker_cpu_url: "http://localhost:8042",
  docker_gpu_url: "http://localhost:8043",
  cloud_url: nil,  # Set via settings or env

  # Active local backend
  active_local_backend: :docker_cpu,

  # Timeouts
  standard_timeout_ms: 900_000,   # 15 minutes
  enhanced_timeout_ms: 1_200_000, # 20 minutes
  max_timeout_ms: 1_200_000,      # 20 minutes cap
  status_poll_timeout_ms: 10_000,

  # Circuit breaker
  circuit_failure_threshold: 5,
  circuit_open_timeout_ms: 30_000,
  circuit_half_open_probes: 1,

  # Health checks
  health_check_interval_ms: 30_000,
  health_check_jitter_percent: 20,
  health_local_timeout_ms: 10_000,
  health_cloud_timeout_ms: 20_000,
  health_stale_threshold_ms: 90_000,

  # Retry (idempotent ops only)
  retry_max_attempts: 3,
  retry_base_delay_ms: 1_000,
  retry_max_delay_ms: 30_000,
  retry_jitter_percent: 20,

  # SSE
  sse_reconnect_delays: [1_000, 2_000, 5_000, 10_000, 30_000],
  sse_heartbeat_timeout_ms: 60_000,

  # Polling
  poll_interval_ms: 250,

  # Telemetry
  progress_sample_rate: 10  # Emit every 10%
```

---

## Part 11: Testing Strategy

### 11.1 Test Module Structure

```
test/lumainus/conversion/
├── job_test.exs
├── job_status_test.exs
├── policy_test.exs
├── service_test.exs
├── application/
│   └── job_tracker_test.exs
├── infrastructure/
│   ├── backend_router_test.exs
│   ├── health_manager_test.exs
│   └── resilience/
│       ├── circuit_breaker_test.exs
│       └── retry_policy_test.exs
├── backends/
│   ├── local_backend_test.exs
│   └── cloud_backend_test.exs
└── support/
    ├── mock_backend.ex
    └── test_helpers.ex
```

### 11.2 Mock Backend

```elixir
defmodule Lumainus.Conversion.Support.MockBackend do
  @moduledoc """
  Per-test mock backend using Agent for isolation.

  Each test starts its own mock with `start_supervised!/1`.
  """

  @behaviour Lumainus.Conversion.Backend

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    initial_state = Keyword.get(opts, :state, %{
      health: :healthy,
      enqueue_response: {:ok, %{"job_id" => "test-123"}},
      status_response: {:ok, %{"state" => "completed", "result" => %{}}},
      await_response: {:ok, %{"markdown" => "# Test"}}
    })

    Agent.start_link(fn -> initial_state end, name: name)
  end

  def set_health(name, health), do: Agent.update(name, &Map.put(&1, :health, health))
  def set_enqueue_response(name, resp), do: Agent.update(name, &Map.put(&1, :enqueue_response, resp))
  def set_status_response(name, resp), do: Agent.update(name, &Map.put(&1, :status_response, resp))
  def set_await_response(name, resp), do: Agent.update(name, &Map.put(&1, :await_response, resp))

  @impl true
  def enqueue(_binary, opts) do
    name = Keyword.fetch!(opts, :mock_name)
    Agent.get(name, & &1.enqueue_response)
  end

  @impl true
  def await(_job_ref, opts) do
    name = Keyword.fetch!(opts, :mock_name)
    Agent.get(name, & &1.await_response)
  end

  @impl true
  def status(job_id) do
    # Would need registry lookup in real implementation
    {:ok, %{"state" => "completed"}}
  end

  @impl true
  def cancel(_job_id), do: :ok

  @impl true
  def health do
    # Would need registry lookup
    {:ok, %{"status" => "healthy"}}
  end

  @impl true
  def name, do: :mock

  @impl true
  def backend_type, do: :local
end
```

### 11.3 Critical Test Cases

```elixir
defmodule Lumainus.Conversion.ServiceTest do
  use Lumainus.DataCase, async: true

  alias Lumainus.Conversion.{Service, Job}
  alias Lumainus.Conversion.Support.MockBackend

  setup do
    # Start per-test mock
    mock_name = :"mock_#{System.unique_integer([:positive])}"
    start_supervised!({MockBackend, name: mock_name, state: %{
      health: :healthy,
      enqueue_response: {:ok, %{"job_id" => Ecto.UUID.generate()}},
      await_response: {:ok, %{"markdown" => "# Test Document"}}
    }})

    %{mock_name: mock_name}
  end

  describe "submit/2" do
    test "creates job with provenance", %{mock_name: mock_name} do
      binary = File.read!("test/fixtures/sample.pdf")

      {:ok, job} = Service.submit(binary,
        filename: "sample.pdf",
        profile: :standard,
        mock_name: mock_name
      )

      assert job.profile == :standard
      assert job.code_version == :v2
      assert job.backend_used != nil
      assert job.state == :queued
    end

    test "rejects oversized files" do
      # 101 MB of zeros
      binary = :binary.copy(<<0>>, 101 * 1024 * 1024)

      assert {:error, :file_too_large} = Service.submit(binary, filename: "big.pdf")
    end

    test "does NOT retry on enqueue failure", %{mock_name: mock_name} do
      MockBackend.set_enqueue_response(mock_name, {:error, {:http_error, 500, %{}}})

      binary = File.read!("test/fixtures/sample.pdf")

      # Should fail immediately, not retry
      assert {:error, _} = Service.submit(binary,
        filename: "sample.pdf",
        mock_name: mock_name
      )

      # Verify only one call was made (via telemetry or mock call count)
    end
  end

  describe "await/2" do
    test "returns result on completion", %{mock_name: mock_name} do
      # Setup: create a job first
      binary = File.read!("test/fixtures/sample.pdf")
      {:ok, job} = Service.submit(binary, filename: "test.pdf", mock_name: mock_name)

      MockBackend.set_await_response(mock_name, {:ok, %{"markdown" => "# Result"}})

      {:ok, result} = Service.await(job.id, timeout_ms: 5_000)

      assert result["markdown"] == "# Result"
    end
  end
end

defmodule Lumainus.Conversion.Infrastructure.Resilience.CircuitBreakerTest do
  use ExUnit.Case, async: true

  alias Lumainus.Conversion.Infrastructure.Resilience.CircuitBreaker

  describe "error classification" do
    test "counts 5xx as failure" do
      assert CircuitBreaker.should_count_as_failure?({:http_error, 500, %{}})
      assert CircuitBreaker.should_count_as_failure?({:http_error, 503, %{}})
    end

    test "counts 429 as failure" do
      assert CircuitBreaker.should_count_as_failure?({:http_error, 429, %{}})
    end

    test "does NOT count 4xx (except 429)" do
      refute CircuitBreaker.should_count_as_failure?({:http_error, 400, %{}})
      refute CircuitBreaker.should_count_as_failure?({:http_error, 404, %{}})
      refute CircuitBreaker.should_count_as_failure?({:http_error, 422, %{}})
    end

    test "counts transport errors" do
      assert CircuitBreaker.should_count_as_failure?({:transport_error, :econnrefused})
      assert CircuitBreaker.should_count_as_failure?({:transport_error, :timeout})
    end
  end

  describe "state transitions" do
    test "opens after threshold failures" do
      breaker = start_supervised!({CircuitBreaker, :test_backend})

      # 5 failures should open
      for _ <- 1..5 do
        CircuitBreaker.record_failure(:test_backend, {:http_error, 500, %{}})
      end

      assert CircuitBreaker.state(:test_backend) == :open
    end

    test "half-open allows exactly one probe" do
      # Setup: open the breaker, then wait for half-open
      # ... test implementation
    end
  end
end
```

---

## Part 12: Directory Structure

```
lib/lumainus/conversion/
├── job.ex                           # Job schema
├── job_status.ex                    # JobStatus view struct
├── processing_profile.ex            # Profile enum + config
├── policy.ex                        # Validation + authorization
├── service.ex                       # Public API
│
├── application/
│   └── job_tracker.ex               # DB-backed job registry + ETS cache
│
├── infrastructure/
│   ├── backend_router.ex            # Profile → backend routing
│   ├── health_manager.ex            # Periodic health checking
│   ├── context.ex                   # Trace/correlation context
│   │
│   ├── resilience/
│   │   ├── circuit_breaker.ex       # Per-backend circuit breaker
│   │   └── retry_policy.ex          # Exponential backoff (idempotent only)
│   │
│   ├── http/
│   │   ├── client.ex                # Req wrapper with trace headers
│   │   └── sse_stream.ex            # SSE with reconnection
│   │
│   └── telemetry/
│       ├── emitter.ex               # Event emission
│       ├── metrics.ex               # Prometheus metric definitions
│       └── handler.ex               # Telemetry event handlers
│
├── backends/
│   ├── local_backend.ex             # CPU/GPU/Docker backends
│   └── cloud_backend.ex             # Vast.ai with InstanceManager
│
└── events.ex                        # PubSub event broadcasting

test/lumainus/conversion/
├── job_test.exs
├── job_status_test.exs
├── policy_test.exs
├── service_test.exs
├── application/
│   └── job_tracker_test.exs
├── infrastructure/
│   ├── backend_router_test.exs
│   ├── health_manager_test.exs
│   └── resilience/
│       ├── circuit_breaker_test.exs
│       └── retry_policy_test.exs
├── backends/
│   ├── local_backend_test.exs
│   └── cloud_backend_test.exs
└── support/
    ├── mock_backend.ex
    └── test_helpers.ex
```

---

## Part 13: Key Implementation Rules

### DO:
1. Store job→backend mapping in database before calling backend
2. Use `code_version` to route all operations for a job consistently
3. Classify errors before tripping circuit breakers (5xx, 429, transport only)
4. Retry only idempotent operations (health, status, SSE reconnect)
5. Sample progress telemetry (every 10%)
6. Keep provenance in storage even if UI hides it
7. Treat stale health (>90s) as `:unknown`, not healthy
8. Limit half-open to exactly 1 concurrent probe
9. Inject trace headers to Python for correlation
10. Use bounded tags in metrics (profile, backend_type, status_bucket)

### DON'T:
1. Retry enqueue or convert operations (not idempotent)
2. Count 4xx errors (except 429) as circuit breaker failures
3. Put tenant_id, job_id, or error strings in metric tags
4. Drop provenance columns without replacement
5. Trust health status older than 90 seconds
6. Allow unbounded probes in half-open state
7. Over-abstract existing working code (keep InstanceManager)

---

## Part 14: Migration from v1

This specification assumes **greenfield implementation**. However, when deployed alongside existing code:

1. **Database:** New `conversion_jobs` table coexists with existing `ingestion_jobs`
2. **Feature flag:** Route by user/tenant to v2 path
3. **Jobs carry version:** `code_version: :v2` ensures consistent routing
4. **Provenance preserved:** Existing `docling_backend` patterns maintained in document metadata

The existing `InstanceManager` (1,377 lines) should be reused for Vast.ai provisioning rather than rewritten.

---

## Appendix A: Telemetry Event Reference

| Event | Measurements | Tags |
|-------|--------------|------|
| `[:lumainus, :conversion, :job, :submitted]` | count: 1 | profile, backend_type |
| `[:lumainus, :conversion, :job, :completed]` | count: 1, duration_ms | profile, backend_type |
| `[:lumainus, :conversion, :job, :failed]` | count: 1 | profile, backend_type, error_type |
| `[:lumainus, :conversion, :job, :cancelled]` | count: 1 | profile, backend_type |
| `[:lumainus, :conversion, :job, :progress]` | progress (0-100) | profile, backend_type |
| `[:lumainus, :conversion, :circuit, :opened]` | count: 1 | backend |
| `[:lumainus, :conversion, :circuit, :closed]` | count: 1 | backend |
| `[:lumainus, :conversion, :circuit, :rejected]` | count: 1 | backend |
| `[:lumainus, :conversion, :retry, :scheduled]` | count: 1, delay_ms | attempt |
| `[:lumainus, :conversion, :retry, :exhausted]` | count: 1 | attempts |
| `[:lumainus, :conversion, :health, :checked]` | latency_ms | backend |
| `[:lumainus, :conversion, :health, :unhealthy]` | count: 1 | backend |
| `[:lumainus, :conversion, :sse, :connected]` | count: 1 | — |
| `[:lumainus, :conversion, :sse, :reconnecting]` | count: 1, delay_ms | — |
| `[:lumainus, :conversion, :sse, :error]` | count: 1 | — |
| `[:lumainus, :conversion, :http, :request]` | duration_ms | method, status_bucket, backend_type |

---

## Appendix B: Configuration Defaults Summary

| Setting | Default | Notes |
|---------|---------|-------|
| File size limit | 100 MB | |
| Standard timeout | 15 min | |
| Enhanced timeout | 20 min | |
| Max timeout | 20 min | Hard cap |
| Circuit threshold | 5 failures | |
| Circuit open time | 30s | |
| Half-open probes | 1 | |
| Health interval | 30s ±20% | |
| Health timeout (local) | 10s | |
| Health timeout (cloud) | 20s | |
| Health stale threshold | 90s | |
| Retry max attempts | 3 | Idempotent only |
| Retry base delay | 1s | |
| Retry max delay | 30s | |
| Retry jitter | 20% | |
| SSE reconnect delays | [1,2,5,10,30]s | |
| SSE heartbeat timeout | 60s | |
| Poll interval | 250ms | |
| Progress sample rate | 10% | |

---

*End of Specification*
