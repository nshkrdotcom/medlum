# Docling Elixir Core Integration

**Date:** November 26, 2025
**Component:** `lib/medlum/docling/`

---

## Executive Summary

The Medlum project implements a sophisticated, multi-backend Docling PDF-to-Markdown conversion system with a unified Elixir API that abstracts 5 different deployment targets. The architecture uses a facade pattern with backend-specific implementations, allowing seamless switching between local (CPU/GPU) and cloud (Vast.ai) backends.

---

## 1. File Structure and Organization

### Directory Layout

```
lib/medlum/docling/
├── docling.ex                    # Main facade module
├── setting.ex                    # Ecto schema for DB persistence
├── settings.ex                   # Settings service layer
├── backend.ex                    # Behavior/protocol definition
├── http.ex                       # Shared HTTP client
├── queue.ex                      # Queue facade
├── health_check.ex               # Health probe schema
├── health_check_worker.ex        # Oban cron worker
├── sse_consumer.ex               # Server-Sent Events consumer
├── backends/
│   ├── local.ex                  # Local (Docker/Native) backend
│   ├── remote.ex                 # Remote HTTP backend
│   └── vast_ai.ex               # Vast.ai cloud backend
└── vast_ai/
    ├── instance_manager.ex       # Instance lifecycle management
    ├── activity_tracker.ex       # Usage tracking
    ├── auto_shutdown.ex          # Cost optimization
    ├── provisioning_state.ex     # State management
    └── start_tracker.ex          # Startup tracking
```

---

## 2. Core Architecture: Facade Pattern with Multi-Backend Support

### Main Module: `Medlum.Docling`

**Purpose**: Unified API that abstracts backend selection and configuration.

### Backend Catalog

```elixir
@backend_modules %{
  native_cpu: Medlum.Docling.Backends.Local,
  native_gpu: Medlum.Docling.Backends.Local,
  docker_cpu: Medlum.Docling.Backends.Local,
  docker_gpu: Medlum.Docling.Backends.Local,
  vast_ai: Medlum.Docling.Backends.VastAI,
  # Legacy aliases
  local: Medlum.Docling.Backends.Local,
  remote: Medlum.Docling.Backends.Remote,
  fast: Medlum.Docling.Backends.Remote
}
```

### Backend Types Classification

- **Local Backends (4)**: `native_cpu`, `native_gpu`, `docker_cpu`, `docker_gpu`
  - All map to `Medlum.Docling.Backends.Local`
  - Different ports: 8040, 8041, 8042, 8043
  - Selectable via admin setting `active_local_backend`

- **Cloud Backends (1)**: `vast_ai`
  - Maps to `Medlum.Docling.Backends.VastAI`
  - Port 8044
  - Auto-provisioning with cost optimization

### User-Facing Mode System

```elixir
@user_mode_aliases %{
  :local => :local,
  :cloud => :cloud,
  # Legacy
  :fast => :cloud
}
```

Users choose between "local" (free) and "cloud" ($$$), not specific backend names.

### Public API Methods

| Method | Purpose | Async? |
|--------|---------|--------|
| `convert/2` | Synchronous PDF-to-Markdown | No |
| `enqueue/2` | Queue async job | Yes (fire & forget) |
| `await/2` | Poll/stream for job results | Yes (blocking await) |
| `health/1` | Health check endpoint | No |
| `cancel/2` | Cancel running job | N/A |
| `capabilities/1` | List backend features | N/A |
| `backend/1` | Resolve backend module | N/A |

---

## 3. Backend Resolution Logic

### Resolution Flow

```
opts[:backend] (explicit override)
  |
  v (if provided)
opts[:mode] (user-facing "local"/"cloud")
  |
  v (if provided)
active_local_backend() (from config or DB)
  |
  v (if neither provided)
:docker_cpu (hardcoded default)
```

### Key Functions

**`backend_name_from_opts/1`**: Determines which backend to use
- Priority: explicit backend > user mode > active local backend > default
- Normalizes string/atom inputs to canonical atoms

**`normalize_backend_name/1`**: Converts any input to canonical atom
- Handles: atoms, strings (case-insensitive)
- Uses `@backend_aliases` map for normalization
- Supports legacy names (`local`, `remote`, `fast`)

**`resolve_mode_to_backend/1`**: Converts user mode to actual backend
```elixir
:local  -> active_local_backend()
:cloud  -> :vast_ai
```

**`url_for_backend/1`**: Retrieves endpoint URL
```elixir
:native_cpu -> native_cpu_url
:native_gpu -> native_gpu_url
:docker_cpu -> docker_cpu_url
:docker_gpu -> docker_gpu_url
:vast_ai    -> cloud_url
```

---

## 4. Configuration Management (Dual-Source Strategy)

### Configuration Hierarchy

The system implements a sophisticated config merging strategy with three sources:

```
1. Environment Variables (highest priority if prefer_env_overrides is true)
2. Database (Setting record in docling_settings table)
3. Application Config (config/config.exs)
```

### Function: `config/0`

Located in `Medlum.Docling`, this function:
1. Fetches environment config from `:medlum, :docling` application env
2. Checks `prefer_env_overrides` flag
3. If true: returns env config with defaults
4. If false: merges DB config with env defaults

### Database Schema: `Medlum.Docling.Setting`

**Fields**:
```elixir
default_mode: :string (default: "local")
active_local_backend: :string (default: "docker_cpu")

# Backend URLs (5 distinct)
native_cpu_url: :string
native_gpu_url: :string
docker_cpu_url: :string
docker_gpu_url: :string
cloud_url: :string

# Legacy fields (backward compatibility)
backend: :string (default: "local")
local_url: :string
remote_url: :string

# Timing
timeout_ms: :integer
poll_interval_ms: :integer (default: 250)
progress_min_interval_ms: :integer (default: 50)

# Singleton constraint
singleton: :boolean (default: true)
```

**Validation**:
- `default_mode`: must be in `["local", "cloud"]`
- `active_local_backend`: must be in `["native_cpu", "native_gpu", "docker_cpu", "docker_gpu", "vast_ai"]`
- All URL fields: HTTPS required (HTTP allowed only for localhost/127.0.0.1)
- Timing fields: must be positive integers
- Singleton constraint enforced via database unique constraint

---

## 5. Backend Protocol & Implementation Pattern

### Behavior: `Medlum.Docling.Backend`

**Required Callbacks**:
```elixir
@callback convert(binary :: binary(), opts :: convert_opts()) :: result()
@callback enqueue(binary :: binary(), opts :: convert_opts()) :: {:ok, job()} | {:error, term()}
@callback await(job :: job(), opts :: await_opts()) :: result()
@callback health() :: {:ok, map()} | {:error, term()}
@callback cancel(job_id :: String.t()) :: :ok | {:error, term()}

@optional_callbacks [cancel: 1, capabilities: 0]
```

**Type Definitions**:
```elixir
@type convert_opts :: [
  filename: String.t(),
  content_type: String.t(),
  byte_size: non_neg_integer(),
  timeout_ms: non_neg_integer(),
  job_id: String.t(),
  upload_id: String.t()
]

@type job :: %{
  job_id: String.t(),
  timeout_ms: non_neg_integer(),
  timeout_at: DateTime.t(),
  backend: module(),
  metadata: map()
}
```

### Backend Implementations

#### 1. **Local Backend** (`Backends.Local`)
- **Scope**: Development/on-premise deployments
- **Config**: `local_url` or `docker_cpu_url`
- **Default**: `http://127.0.0.1:8042`
- **Implementation**: Simple delegation to `HTTP` module with local URL
- **Capabilities**: `[:sync, :async, :sse, :cancel]`

#### 2. **Remote Backend** (`Backends.Remote`)
- **Scope**: Pre-provisioned GPU servers, shared services
- **Config**: `remote_url` or `base_url`
- **Implementation**: Similar to Local, uses configured URL
- **Capabilities**: `[:sync, :async, :sse, :cancel]`
- **Status**: Legacy (replaced by per-port backends)

#### 3. **Vast.ai Backend** (`Backends.VastAI`)
- **Scope**: Cloud GPU provisioning with cost optimization
- **Config**: `cloud_url`
- **Features**:
  - Automatic instance provisioning via `InstanceManager`
  - Activity-based cost optimization (`ActivityTracker`, `AutoShutdown`)
  - Fallback health checks via direct IP when Cloudflare fails
  - Metadata tracking (instance ID, endpoint, IP)
- **Capabilities**: `[:sync, :async, :sse, :cancel, :auto_provision, :gpu]`

---

## 6. HTTP Client and Communication Layer

### Module: `Medlum.Docling.HTTP`

**Purpose**: Centralized HTTP handling for all backends

**Shared Multipart Upload**:
```elixir
build_multipart_fields(binary, opts, extra)
```
Constructs form fields:
- `:file` - PDF binary with metadata
- `:output_markdown` - true for conversion requests
- `:wait` - false for async (enqueue), true/absent for sync
- `:job_id` - Optional tracking ID

**API Endpoints**:

| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/convert` | Synchronous conversion |
| POST | `/jobs` | Enqueue async job |
| GET | `/jobs/:id/status` | Poll job status |
| GET | `/jobs/:id/stream` | SSE event stream |
| DELETE | `/jobs/:id` | Cancel job |
| GET | `/health` | Health check |

### SSE-First Awaiting with Polling Fallback

**Function**: `HTTP.await/3`

**Strategy**:
```
prefer_sse? = true (default)
├─ await_sse()          <- Try real-time SSE streaming
│  └─ {:fallback, reason}
│     └─ poll_status()  <- Fall back to 250ms polling
└─ poll_status()        <- If prefer_sse? = false
```

**SSE Consumer** (`SSEConsumer.ex`):
- Subscribes to `/jobs/:id/stream` endpoint
- Supervised task via `Medlum.TaskSupervisor`
- Sends messages:
  - `{:sse_event, job_id, event_map}` - Progress update
  - `{:sse_done, job_id, :completed | :failed}` - Terminal state
  - `{:sse_error, job_id, reason}` - Connection error
- Parses SSE frames with double-newline delimiter

---

## 7. Async Job Management

### Module: `Medlum.Docling.Queue`

**Purpose**: Optional async job queueing with two modes

**Modes**:
```elixir
@inline_mode :inline          # Convert immediately (default)
:http_queue                   # Queue in Docling service
```

**Job Structure**:
```elixir
%{
  job_id: binary(),
  timeout_ms: non_neg_integer(),
  timeout_at: DateTime.t(),
  mode: atom(),
  binary: binary() | nil,      # Inline mode only
  convert_opts: keyword(),
  backend: module(),           # HTTP queue mode only
  backend_name: atom()         # HTTP queue mode only
}
```

---

## 8. Health Check Infrastructure

### Schemas & Workers

**Schema**: `Medlum.Docling.HealthCheck`
```elixir
status: :string           # "healthy" | "unreachable"
details: :map            # Response body or error info
responded_at: :utc_datetime
```

**Worker**: `Medlum.Docling.HealthCheckWorker`
- Oban-based cron job
- Runs every 5 minutes (configured via cron: `"*/5 * * * *"`)
- Calls `Docling.health()` and persists result
- Queue: `:health_checks` (1 worker)

---

## 9. Vast.ai-Specific Components

Located in `lib/medlum/docling/vast_ai/`:

### Instance Manager (`instance_manager.ex`)
- Maintains singleton GPU instance lifecycle
- Methods:
  - `ensure_instance()` - Provision if needed
  - `get_endpoint()` - Current instance URL
  - `update_activity()` - Refresh idle timeout
  - `current_instance_id()` - Active instance ID
  - `set_endpoint()` - Update cached endpoint

### Activity Tracker (`activity_tracker.ex`)
- Tracks API usage for cost monitoring
- Records: timestamps, operation types, status

### Auto-Shutdown (`auto_shutdown.ex`)
- Oban worker for cost optimization
- Configuration:
  - `check_interval_minutes`: 5
  - `idle_timeout_minutes`: 15
- Destroys idle instances to minimize cloud costs

---

## 10. Configuration in config/config.exs

```elixir
config :medlum, :docling,
  # User default mode
  default_mode: :local,

  # Which local backend is active
  active_local_backend: :docker_cpu,

  # 5 Backend URLs
  native_cpu_url: "http://127.0.0.1:8040",
  native_gpu_url: "http://127.0.0.1:8041",
  docker_cpu_url: "http://127.0.0.1:8042",
  docker_gpu_url: "http://127.0.0.1:8043",
  cloud_url: System.get_env("DOCLING_CLOUD_URL"),

  # Timing
  timeout_ms: 1_200_000,        # 20 minutes
  poll_interval_ms: 250,
  progress_min_interval_ms: 50,

  # Queue mode
  queue_mode: :http_queue,

  # Health checks
  health_cron: "*/5 * * * *"
```

---

## 11. Key Design Patterns

### 1. **Behavior-Based Polymorphism**
- `Medlum.Docling.Backend` behavior defines contract
- Multiple implementations (Local, Remote, VastAI)
- Runtime dispatch via `backend_module/1`

### 2. **Facade Pattern**
- `Medlum.Docling` hides backend complexity
- Transparent backend switching via config/opts
- Unified API regardless of backend

### 3. **Singleton Configuration Pattern**
- `Medlum.Docling.Settings.fetch_or_init()` ensures single record
- Database unique constraint on `:singleton` field
- Supports both env overrides and DB persistence

### 4. **SSE with Polling Fallback**
- Prefer real-time streaming when available
- Graceful degradation to polling
- Timeout-aware without tight polling loops

### 5. **Activity-Based Resource Management**
- `ActivityTracker` for cost monitoring
- `AutoShutdown` for idle destruction
- Integration with `InstanceManager` lifecycle

---

## 12. Data Flow Diagrams

### Synchronous Conversion Flow

```
User.convert(binary, backend: :docker_cpu)
  |
  v
Docling.convert/2
  ├─ backend_name_from_opts/1 -> :docker_cpu
  ├─ backend_module/1 -> Medlum.Docling.Backends.Local
  v
Backends.Local.convert/2
  v
HTTP.convert/2
  ├─ build_multipart_fields/2
  ├─ POST /convert
  v
Docling Service (localhost:8042)
  v
{:ok, %{"markdown" => "...", ...}}
```

### Asynchronous Job with SSE Flow

```
User.enqueue(binary, backend: :vast_ai)
  |
  v
Docling.enqueue/2
  ├─ Backends.VastAI.enqueue/2
  ├─ ensure_instance/0 (InstanceManager)
  ├─ HTTP.enqueue/2 -> POST /jobs
  ├─ record_activity/0
  v
{:ok, %{job_id: "123", backend: VastAI, metadata: {...}}}

User.await(job)
  |
  v
Docling.await/2
  v
HTTP.await/3
  ├─ prefer_sse? = true
  v
SSEConsumer.subscribe/2
  ├─ Finch.stream GET /jobs/123/stream
  ├─ Parse SSE frames
  ├─ Send {:sse_event, "123", %{...}}
  ├─ Detect terminal state
  ├─ Send {:sse_done, "123", :completed}
  v
receive_sse_events/5
  ├─ on_status callback
  ├─ HTTP.job_status/2 -> /jobs/123/status
  v
{:ok, %{"markdown" => "...", ...}}
```

---

## 13. Potential Abstractions for Extraction

### 1. **Job Enqueuing**
```elixir
# Extract to separate module
Docling.JobEnqueuer
  - handle enqueue/2 logic
  - build job structs
  - manage job metadata
```

### 2. **Backend Resolution**
```elixir
# Extract resolution logic
Docling.BackendResolver
  - normalize_backend_name/1
  - resolve_mode_to_backend/1
  - backend_name_from_opts/1
```

### 3. **URL Management**
```elixir
# Extract URL resolution
Docling.URLProvider
  - url_for_backend/1
  - base_url/1
  - validate_safe_url/2
```

### 4. **Configuration Merging**
```elixir
# Extract config strategy
Docling.ConfigMerger
  - merge_sources/3
  - prefer_env_overrides?/1
```

### 5. **SSE Event Parsing**
```elixir
# Extract SSE-specific handling
Docling.SSEEventHandler
  - parse_sse_events/1
  - sse_event_to_status/1
  - detect_terminal_events/1
```

---

## 14. Key Design Strengths

1. **Pluggable Backends**: Easy to add new deployment targets
2. **Transparent Backend Switching**: No client code changes needed
3. **Robust Fallback Strategy**: SSE->polling->IP-based health fallback
4. **Cost Optimization**: Activity-based auto-shutdown for cloud instances
5. **Backward Compatibility**: Legacy names and fields preserved
6. **Flexible Configuration**: Environment, database, and code-level overrides
7. **Health Monitoring**: Persistent health checks with cron scheduling
8. **Real-Time Progress**: SSE streaming for user feedback
9. **Type Safety**: Behavior-based protocol with specs
