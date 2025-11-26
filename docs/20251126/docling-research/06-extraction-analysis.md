# Docling Service Extraction Analysis

**Date:** November 26, 2025
**Purpose:** Analyze feasibility of extracting Docling integration as standalone service/library

---

## Executive Summary

The Docling integration in Lumainus is well-architected but deeply integrated with the application's multi-tenant model, database schemas, and real-time features. Extraction is **feasible** but requires careful consideration of trade-offs.

**Recommendation:** Extract as a **standalone Elixir library** with pluggable configuration, keeping the Python/Docker infrastructure as-is.

---

## Current Integration Points

### Tightly Coupled Components

| Component | Integration | Difficulty to Extract |
|-----------|-------------|----------------------|
| `Lumainus.Docling.Setting` | Ecto schema, singleton pattern | Medium |
| `Lumainus.Docling.HealthCheck` | Ecto schema, Oban worker | Medium |
| `InstanceManager` | GenServer, tenant-agnostic | Low |
| `Settings.fetch_or_init/0` | Repo dependency | Medium |
| `HealthCheckWorker` | Oban, Application-level | High |
| `VastAI.AutoShutdown` | Oban worker | High |
| PubSub integration | Phoenix.PubSub topics | Medium |
| Web LiveViews | Full Phoenix integration | High |
| IngestionJob/Worker | Oban, tenant model | High |

### Loosely Coupled Components (Easy to Extract)

| Component | Description | Notes |
|-----------|-------------|-------|
| `Lumainus.Docling` (facade) | Pure functions, config-driven | Core extraction target |
| `Lumainus.Docling.HTTP` | HTTP client, no DB deps | Easy |
| `Lumainus.Docling.Backend` | Behavior definition | Easy |
| `Backends.Local` | HTTP wrapper | Easy |
| `Backends.Remote` | HTTP wrapper | Easy |
| `Backends.VastAI` (core) | HTTP + provisioning | Medium (needs API key config) |
| `SSEConsumer` | Task-based SSE handling | Easy |
| `Queue` | Job struct management | Easy |
| Python fork (`docling/`) | Standalone | Easy |
| FastAPI service | Standalone | Easy |
| Docker images | Registry-ready | Easy |
| Scripts | Bash, portable | Easy |

---

## Extraction Options

### Option 1: Standalone Elixir Library (Recommended)

**Scope:** Extract core HTTP/backend layer as `docling_ex` hex package.

**What to extract:**
```
docling_ex/
├── lib/
│   ├── docling.ex              # Main API
│   ├── backend.ex              # Behavior
│   ├── http.ex                 # HTTP client
│   ├── sse_consumer.ex         # SSE handling
│   ├── queue.ex                # Job management
│   └── backends/
│       ├── local.ex
│       ├── remote.ex
│       └── vast_ai.ex
├── test/
└── mix.exs
```

**Configuration model:**
```elixir
# Application config (no database)
config :docling_ex,
  backend: :docker_cpu,
  backends: %{
    native_cpu: "http://127.0.0.1:8040",
    native_gpu: "http://127.0.0.1:8041",
    docker_cpu: "http://127.0.0.1:8042",
    docker_gpu: "http://127.0.0.1:8043",
    vast_ai: System.get_env("DOCLING_CLOUD_URL")
  },
  timeout_ms: 1_200_000,
  poll_interval_ms: 250,
  prefer_sse: true
```

**Pros:**
- Clean separation from Lumainus business logic
- Reusable across projects
- No Ecto/Phoenix dependencies
- Well-defined API contract
- Existing tests are mostly Bypass-based (easy to migrate)

**Cons:**
- Loses database-backed configuration (runtime switching)
- Loses health check persistence
- Loses Vast.ai auto-shutdown (needs external cron/scheduler)
- Consumers must implement their own job queuing

**Estimated Effort:** 1-2 weeks

---

### Option 2: Full Standalone Service (Microservice)

**Scope:** Extract as Phoenix/Plug-based HTTP service that wraps Docling.

**Architecture:**
```
docling_gateway/
├── lib/
│   ├── docling_gateway/
│   │   ├── application.ex
│   │   ├── router.ex
│   │   ├── controllers/
│   │   │   ├── convert_controller.ex
│   │   │   ├── jobs_controller.ex
│   │   │   └── health_controller.ex
│   │   ├── docling/              # Core extraction
│   │   └── vast_ai/              # Provisioning
│   └── docling_gateway_web.ex
└── config/
```

**Pros:**
- Complete independence
- Can be deployed anywhere
- Multi-tenant support possible
- HTTP API makes it language-agnostic

**Cons:**
- Adds network hop for Lumainus
- Need to reimplement job queuing
- Need to reimplement health persistence
- More infrastructure to maintain
- Duplicates FastAPI service functionality

**Estimated Effort:** 3-4 weeks

---

### Option 3: Elixir Library + Application (Hybrid)

**Scope:** Extract core as library, provide optional OTP application for advanced features.

**Structure:**
```
docling_ex/
├── lib/
│   ├── docling/                 # Core library (no deps)
│   │   ├── http.ex
│   │   ├── backend.ex
│   │   └── backends/
│   ├── docling/application/     # Optional OTP app
│   │   ├── instance_manager.ex  # GenServer
│   │   ├── health_checker.ex    # GenServer with configurable callback
│   │   └── auto_shutdown.ex     # GenServer with configurable callback
│   └── docling.ex               # Main API
```

**Usage:**
```elixir
# Minimal (library only)
{:ok, result} = Docling.convert(binary, backend: :docker_cpu)

# With OTP features
children = [
  {Docling.InstanceManager, vast_ai_api_key: "..."},
  {Docling.HealthChecker, callback: &MyApp.record_health/1, interval: :timer.minutes(5)},
  {Docling.AutoShutdown, idle_timeout: :timer.minutes(30)}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

**Pros:**
- Flexible: use as library or full-featured service
- InstanceManager can be reused
- Health checking is callback-based (no Ecto dependency)
- Auto-shutdown is scheduler-agnostic

**Cons:**
- More complex API surface
- Two different usage patterns to document/maintain
- Requires careful design of callback interfaces

**Estimated Effort:** 2-3 weeks

---

## Detailed Pros and Cons Analysis

### Pros of Extraction

#### 1. **Reusability**
- Other Elixir projects can use Docling without Lumainus
- Clear boundaries make testing easier
- Can be open-sourced independently

#### 2. **Maintainability**
- Smaller, focused codebase
- Easier to upgrade Docling (Python) without affecting Lumainus
- Clear versioning and compatibility

#### 3. **Testing**
- Unit tests are already well-isolated
- Bypass mocking works without Phoenix
- Can add property-based tests more easily

#### 4. **Deployment Flexibility**
- Library can be vendored or hex-published
- Docker/Python infrastructure is already standalone
- Scripts are portable

#### 5. **Documentation**
- Self-contained documentation
- Clear API reference
- Example-driven usage

### Cons of Extraction

#### 1. **Loss of Integrated Features**
- Database-backed runtime configuration
- Persistent health check history
- Oban-based scheduling (cron jobs)
- Multi-tenant context passing

#### 2. **Migration Effort**
- Need to update Lumainus to use extracted library
- Potential API changes during extraction
- Test migration and verification

#### 3. **Maintenance Overhead**
- Two repositories to maintain (or monorepo setup)
- Version coordination between library and Lumainus
- Breaking changes affect both

#### 4. **Feature Gaps**
- Extracted library won't have:
  - `fetch_or_init/0` (needs Repo)
  - `record_health/1` (needs Repo)
  - Oban workers (needs Oban)
  - PubSub broadcasts (needs Phoenix.PubSub)
- Consumers must implement these

#### 5. **Configuration Complexity**
- Library needs different config model
- Database-backed settings become application-level
- Runtime backend switching more complex

---

## Extraction Roadmap

### Phase 1: Prepare (Week 1)

1. **Identify exact module boundaries**
   - Mark modules as "core" vs "integration"
   - Document dependencies between modules

2. **Create interface contracts**
   - Define callback behaviors for:
     - Configuration provider
     - Health recorder
     - Activity tracker
   - Document required vs optional callbacks

3. **Extract Python infrastructure first**
   - `docling/` fork is already standalone
   - `docling_service/` FastAPI is standalone
   - Scripts just need path updates

### Phase 2: Core Extraction (Week 2)

1. **Create new mix project**
   ```bash
   mix new docling_ex
   ```

2. **Move core modules**
   - `http.ex` (no changes needed)
   - `backend.ex` (no changes needed)
   - `backends/*.ex` (minimal changes)
   - `sse_consumer.ex` (no changes needed)
   - `queue.ex` (no changes needed)

3. **Adapt facade module**
   - Replace `Application.get_env` with configurable provider
   - Remove Repo dependencies
   - Use callback-based health recording

4. **Migrate tests**
   - Copy Bypass-based tests
   - Update module references
   - Add new configuration tests

### Phase 3: Integration Layer (Week 3)

1. **Create Lumainus adapter**
   ```elixir
   defmodule Lumainus.Docling.Adapter do
     @behaviour Docling.ConfigProvider
     @behaviour Docling.HealthRecorder

     def get_config, do: Settings.to_config_keywords(...)
     def record_health(result), do: HealthCheck.create(...)
   end
   ```

2. **Update Lumainus to use library**
   - Add `docling_ex` dependency
   - Update `Lumainus.Docling` to delegate to library
   - Keep Oban workers in Lumainus

3. **Verify all tests pass**
   - Run Lumainus test suite
   - Run extracted library test suite

### Phase 4: Polish (Week 4)

1. **Documentation**
   - README with usage examples
   - API documentation
   - Configuration guide

2. **CI/CD**
   - GitHub Actions for library
   - Hex publish automation (if public)

3. **Versioning**
   - Semantic versioning
   - Changelog

---

## Recommended Integration Points for Extracted Library

### Configuration Interface

```elixir
defmodule Docling.Config do
  @callback backends() :: %{atom() => String.t()}
  @callback active_backend() :: atom()
  @callback timeout_ms() :: non_neg_integer()
  @callback poll_interval_ms() :: non_neg_integer()
  @callback prefer_sse?() :: boolean()
end
```

### Health Recording Interface

```elixir
defmodule Docling.HealthRecorder do
  @callback record_health(backend :: atom(), result :: map()) :: :ok | {:error, term()}
end
```

### Activity Tracking Interface

```elixir
defmodule Docling.ActivityTracker do
  @callback record_activity(backend :: atom(), operation :: atom()) :: :ok
  @callback last_activity(backend :: atom()) :: DateTime.t() | nil
end
```

### Usage Example (Consumer)

```elixir
# In consumer application
defmodule MyApp.DoclingConfig do
  @behaviour Docling.Config

  def backends do
    %{
      docker_cpu: Application.get_env(:my_app, :docling_url, "http://localhost:8042")
    }
  end

  def active_backend, do: :docker_cpu
  def timeout_ms, do: 1_200_000
  def poll_interval_ms, do: 250
  def prefer_sse?, do: true
end

# Use library
{:ok, result} = Docling.convert(binary,
  filename: "test.pdf",
  config: MyApp.DoclingConfig
)
```

---

## Decision Matrix

| Criteria | Option 1 (Library) | Option 2 (Service) | Option 3 (Hybrid) |
|----------|-------------------|-------------------|-------------------|
| Complexity | Low | High | Medium |
| Reusability | High | High | High |
| Effort | 1-2 weeks | 3-4 weeks | 2-3 weeks |
| Maintenance | Low | High | Medium |
| Feature Parity | Partial | Full | High |
| Network Overhead | None | Additional hop | None |
| Testing | Easy | Complex | Medium |

---

## Conclusion

### Recommended Approach: Option 3 (Hybrid)

Extract as an Elixir library with optional OTP application components:

1. **Core library** (`Docling`) - Pure functions, no OTP deps
2. **Optional GenServers** - InstanceManager, HealthChecker, AutoShutdown
3. **Callback behaviors** - For configuration, health recording, activity tracking

This provides:
- Maximum flexibility for consumers
- Minimal migration effort for Lumainus
- Clear extension points
- No infrastructure duplication

### What Stays in Lumainus

- Ecto schemas (`Setting`, `HealthCheck`)
- Oban workers (`HealthCheckWorker`, `AutoShutdown`)
- PubSub integration
- LiveView components
- Multi-tenant context

### What Gets Extracted

- HTTP client (`http.ex`)
- Backend behavior and implementations
- SSE consumer
- Queue management
- Core facade (adapted for callbacks)
- GenServers (optional, callback-based)

### Next Steps

1. Review this analysis with team
2. Decide on extraction scope (library vs hybrid)
3. Create extraction branch
4. Begin Phase 1 (prepare boundaries)
5. Document API contract
6. Execute extraction
7. Update Lumainus integration
8. Comprehensive testing
9. Documentation and release
