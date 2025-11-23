# Docling Backend Abstraction Design

**Date:** November 23, 2025
**Status:** Proposal
**Author:** Claude Code

---

## Executive Summary

Design a universal backend abstraction for Docling PDF-to-Markdown conversion that supports local CPU, remote HTTP, and cloud GPU (Vast.ai) backends through a clean Elixir behaviour interface. The goal is to make cloud GPU optional while maintaining a simple, consistent API for development and production use.

---

## Problem Statement

The current Docling integration has grown organically with multiple modes:
- **Inline mode**: Direct synchronous conversion
- **HTTP queue mode**: Async job submission with SSE/polling

However, it lacks:
1. A formal backend abstraction for different deployment targets
2. Clear separation between the "what" (convert PDF) and "where" (local/remote/cloud)
3. Easy switching between backends without code changes
4. A path to add future backends (gRPC, Lambda, etc.)

---

## Design Goals

1. **Simple API**: Single entry point regardless of backend
2. **Configuration-driven**: Switch backends via config, not code
3. **Development-friendly**: Local CPU should "just work" with zero setup
4. **Production-ready**: Cloud GPU is transparent behind the same interface
5. **Observable**: Consistent progress/status reporting across backends
6. **Testable**: Easy to mock/stub for tests

---

## Proposed Architecture

### Layer Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Application Code                      │
│            (IngestionProcessor, Reports, etc.)           │
└──────────────────────────┬──────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│                  Lumainus.Docling                        │
│              (Unified API / Façade)                      │
│                                                          │
│  convert/2, enqueue/2, await/2, health/0, cancel/1      │
└──────────────────────────┬──────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│              Lumainus.Docling.Backend                    │
│                   (Behaviour)                            │
│                                                          │
│  @callback convert(binary, opts) :: result              │
│  @callback enqueue(binary, opts) :: {:ok, job}          │
│  @callback await(job, opts) :: result                   │
│  @callback health() :: {:ok, map} | {:error, term}      │
│  @callback cancel(job_id) :: :ok | {:error, term}       │
└──────────────────────────┬──────────────────────────────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
       ┌──────────┐  ┌──────────┐  ┌──────────┐
       │  Local   │  │   HTTP   │  │  VastAI  │
       │ Backend  │  │ Backend  │  │ Backend  │
       └──────────┘  └──────────┘  └──────────┘
           │              │              │
           ▼              ▼              ▼
       localhost:     any remote     Vast.ai
        8042          endpoint       provisioned
```

---

## Implementation Details

### 1. Backend Behaviour

```elixir
# lib/lumainus/docling/backend.ex
defmodule Lumainus.Docling.Backend do
  @moduledoc """
  Behaviour for Docling conversion backends.

  Implement this behaviour to add support for new Docling deployment targets.
  """

  @type convert_opts :: [
    filename: String.t(),
    content_type: String.t(),
    byte_size: non_neg_integer(),
    timeout_ms: non_neg_integer(),
    job_id: String.t()
  ]

  @type job :: %{
    job_id: String.t(),
    timeout_ms: non_neg_integer(),
    timeout_at: DateTime.t(),
    backend: module(),
    metadata: map()
  }

  @type await_opts :: [
    on_status: (map() -> :ok),
    poll_interval_ms: non_neg_integer()
  ]

  @type result :: {:ok, map()} | {:error, term()}

  @doc "Convert a PDF binary synchronously"
  @callback convert(binary :: binary(), opts :: convert_opts()) :: result()

  @doc "Enqueue a conversion job (async)"
  @callback enqueue(binary :: binary(), opts :: convert_opts()) :: {:ok, job()} | {:error, term()}

  @doc "Await completion of a queued job"
  @callback await(job :: job(), opts :: await_opts()) :: result()

  @doc "Check backend health/availability"
  @callback health() :: {:ok, map()} | {:error, term()}

  @doc "Cancel a running job (best effort)"
  @callback cancel(job_id :: String.t()) :: :ok | {:error, term()}

  @doc "Return backend capabilities"
  @callback capabilities() :: [atom()]

  @optional_callbacks [cancel: 1, capabilities: 0]
end
```

### 2. Backend Implementations

#### 2.1 Local Backend (Development Default)

```elixir
# lib/lumainus/docling/backends/local.ex
defmodule Lumainus.Docling.Backends.Local do
  @moduledoc """
  Local Docling backend for development.

  Expects Docling service running on localhost:8042 (CPU mode).
  This is the default backend - no cloud setup required.
  """

  @behaviour Lumainus.Docling.Backend

  @default_url "http://127.0.0.1:8042"

  @impl true
  def convert(binary, opts) do
    # Delegate to HTTP client with local URL
    Lumainus.Docling.HTTP.convert(binary, opts, base_url: url())
  end

  @impl true
  def enqueue(binary, opts) do
    with {:ok, response} <- Lumainus.Docling.HTTP.enqueue(binary, opts, base_url: url()) do
      {:ok, build_job(response, opts)}
    end
  end

  @impl true
  def await(job, opts) do
    Lumainus.Docling.HTTP.await(job, opts, base_url: url())
  end

  @impl true
  def health do
    Lumainus.Docling.HTTP.health(base_url: url())
  end

  @impl true
  def cancel(job_id) do
    Lumainus.Docling.HTTP.cancel(job_id, base_url: url())
  end

  @impl true
  def capabilities, do: [:sync, :async, :sse, :cancel]

  defp url do
    Application.get_env(:lumainus, :docling, [])
    |> Keyword.get(:local_url, @default_url)
  end

  defp build_job(response, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 1_200_000)

    %{
      job_id: response["job_id"],
      timeout_ms: timeout_ms,
      timeout_at: DateTime.add(DateTime.utc_now(), timeout_ms, :millisecond),
      backend: __MODULE__,
      metadata: %{url: url()}
    }
  end
end
```

#### 2.2 Remote HTTP Backend

```elixir
# lib/lumainus/docling/backends/remote.ex
defmodule Lumainus.Docling.Backends.Remote do
  @moduledoc """
  Remote HTTP backend for any Docling service endpoint.

  Use this for pre-provisioned GPU servers or shared services.
  Configure via :docling :remote_url.
  """

  @behaviour Lumainus.Docling.Backend

  @impl true
  def convert(binary, opts) do
    Lumainus.Docling.HTTP.convert(binary, opts, base_url: url())
  end

  @impl true
  def enqueue(binary, opts) do
    with {:ok, response} <- Lumainus.Docling.HTTP.enqueue(binary, opts, base_url: url()) do
      {:ok, build_job(response, opts)}
    end
  end

  @impl true
  def await(job, opts) do
    Lumainus.Docling.HTTP.await(job, opts, base_url: url())
  end

  @impl true
  def health do
    Lumainus.Docling.HTTP.health(base_url: url())
  end

  @impl true
  def cancel(job_id) do
    Lumainus.Docling.HTTP.cancel(job_id, base_url: url())
  end

  @impl true
  def capabilities, do: [:sync, :async, :sse, :cancel]

  defp url do
    Application.get_env(:lumainus, :docling, [])
    |> Keyword.get(:remote_url)
    || raise "Remote backend requires :docling :remote_url config"
  end

  defp build_job(response, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 1_200_000)

    %{
      job_id: response["job_id"],
      timeout_ms: timeout_ms,
      timeout_at: DateTime.add(DateTime.utc_now(), timeout_ms, :millisecond),
      backend: __MODULE__,
      metadata: %{url: url()}
    }
  end
end
```

#### 2.3 Vast.ai Backend (Cloud GPU)

```elixir
# lib/lumainus/docling/backends/vast_ai.ex
defmodule Lumainus.Docling.Backends.VastAI do
  @moduledoc """
  Vast.ai GPU backend with automatic instance provisioning.

  Provisions RTX 3090 instances on-demand via Vast.ai API.
  Instances are kept alive while jobs are running, then destroyed.

  Requires: VAST_API_KEY environment variable
  """

  @behaviour Lumainus.Docling.Backend

  alias Lumainus.Docling.VastAI.InstanceManager

  @impl true
  def convert(binary, opts) do
    # Ensure we have a running instance
    with {:ok, endpoint} <- InstanceManager.ensure_instance() do
      Lumainus.Docling.HTTP.convert(binary, opts, base_url: endpoint)
    end
  end

  @impl true
  def enqueue(binary, opts) do
    with {:ok, endpoint} <- InstanceManager.ensure_instance(),
         {:ok, response} <- Lumainus.Docling.HTTP.enqueue(binary, opts, base_url: endpoint) do
      {:ok, build_job(response, opts, endpoint)}
    end
  end

  @impl true
  def await(job, opts) do
    endpoint = job.metadata.endpoint
    Lumainus.Docling.HTTP.await(job, opts, base_url: endpoint)
  end

  @impl true
  def health do
    case InstanceManager.get_endpoint() do
      {:ok, endpoint} -> Lumainus.Docling.HTTP.health(base_url: endpoint)
      {:error, :no_instance} -> {:ok, %{status: "no_instance", message: "No active Vast.ai instance"}}
    end
  end

  @impl true
  def cancel(job_id) do
    case InstanceManager.get_endpoint() do
      {:ok, endpoint} -> Lumainus.Docling.HTTP.cancel(job_id, base_url: endpoint)
      _ -> {:error, :no_instance}
    end
  end

  @impl true
  def capabilities, do: [:sync, :async, :sse, :cancel, :auto_provision, :gpu]

  defp build_job(response, opts, endpoint) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 1_200_000)

    %{
      job_id: response["job_id"],
      timeout_ms: timeout_ms,
      timeout_at: DateTime.add(DateTime.utc_now(), timeout_ms, :millisecond),
      backend: __MODULE__,
      metadata: %{
        endpoint: endpoint,
        instance_id: InstanceManager.current_instance_id()
      }
    }
  end
end
```

### 3. Shared HTTP Client

```elixir
# lib/lumainus/docling/http.ex
defmodule Lumainus.Docling.HTTP do
  @moduledoc """
  Shared HTTP client for Docling service communication.

  All backends delegate to this module for actual HTTP calls.
  Handles multipart upload, SSE streaming, and polling.
  """

  alias Lumainus.Docling.SSEConsumer
  require Logger

  @default_timeout 1_200_000

  def convert(binary, opts, http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)

    fields = build_multipart_fields(binary, opts, output_markdown: true)

    request(:post, "#{base_url}/convert",
      form_multipart: fields,
      receive_timeout: timeout
    )
  end

  def enqueue(binary, opts, http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)

    fields = build_multipart_fields(binary, opts, output_markdown: true, wait: false)

    request(:post, "#{base_url}/jobs",
      form_multipart: fields,
      receive_timeout: timeout
    )
  end

  def await(job, opts, http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    on_status = Keyword.get(opts, :on_status, fn _ -> :ok end)
    poll_ms = Keyword.get(opts, :poll_interval_ms, 5_000)
    deadline = System.monotonic_time(:millisecond) + job.timeout_ms

    # Try SSE first, fall back to polling
    case await_sse(job.job_id, base_url, deadline, on_status) do
      {:ok, result} -> {:ok, result}
      {:fallback, _reason} -> poll_status(job.job_id, base_url, deadline, poll_ms, on_status)
      {:error, _} = error -> error
    end
  end

  def health(http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    request(:get, "#{base_url}/health", receive_timeout: 15_000)
  end

  def cancel(job_id, http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)

    case request(:delete, "#{base_url}/jobs/#{job_id}", receive_timeout: 15_000) do
      {:ok, _} -> :ok
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ... (SSE and polling implementation from current queue.ex)
  # This consolidates the existing logic into a reusable module

  defp build_multipart_fields(binary, opts, extra) do
    filename = Keyword.fetch!(opts, :filename)
    content_type = Keyword.get(opts, :content_type, "application/pdf")
    byte_size = Keyword.get(opts, :byte_size, byte_size(binary))
    job_id = Keyword.get(opts, :job_id)

    fields = [
      {:file, {binary, filename: filename, content_type: content_type, size: byte_size}}
    ]

    fields = if extra[:output_markdown], do: [{:output_markdown, "true"} | fields], else: fields
    fields = if extra[:wait] == false, do: [{:wait, "false"} | fields], else: fields
    fields = if job_id, do: [{:job_id, job_id} | fields], else: fields

    fields
  end

  defp request(method, url, opts) do
    case Req.request([method: method, url: url] ++ opts) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, decode_body(resp.body)}
      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, decode_body(body)}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_body(%{} = body), do: body
  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{"raw" => body}
    end
  end
  defp decode_body(body), do: body

  defp await_sse(job_id, base_url, deadline, on_status) do
    # Implementation from current queue.ex await_sse/4
    # ...
  end

  defp poll_status(job_id, base_url, deadline, poll_ms, on_status) do
    # Implementation from current queue.ex poll_remote/4
    # ...
  end
end
```

### 4. Updated Façade Module

```elixir
# lib/lumainus/docling.ex (updated)
defmodule Lumainus.Docling do
  @moduledoc """
  Unified API for Docling PDF-to-Markdown conversion.

  This module provides a single entry point regardless of which backend
  is configured. The backend is selected via configuration.

  ## Configuration

      config :lumainus, :docling,
        backend: :local,  # or :remote, :vast_ai
        timeout_ms: 1_200_000,
        # Backend-specific options
        local_url: "http://127.0.0.1:8042",
        remote_url: "http://gpu-server:8042",
        vast_ai: [
          api_key: "...",
          gpu_name: "RTX_3090",
          min_disk_gb: 20
        ]

  ## Usage

      # Synchronous conversion
      {:ok, result} = Lumainus.Docling.convert(pdf_binary, filename: "doc.pdf")

      # Async with progress
      {:ok, job} = Lumainus.Docling.enqueue(pdf_binary, filename: "doc.pdf")
      {:ok, result} = Lumainus.Docling.await(job, on_status: &handle_progress/1)
  """

  require Logger

  @backends %{
    local: Lumainus.Docling.Backends.Local,
    remote: Lumainus.Docling.Backends.Remote,
    vast_ai: Lumainus.Docling.Backends.VastAI
  }

  @doc "Convert a PDF binary to markdown"
  def convert(binary, opts \\ []) when is_binary(binary) do
    backend().convert(binary, merge_opts(opts))
  end

  @doc "Enqueue a conversion job"
  def enqueue(binary, opts \\ []) when is_binary(binary) do
    backend().enqueue(binary, merge_opts(opts))
  end

  @doc "Await a queued job"
  def await(job, opts \\ []) do
    backend_module = job.backend || backend()
    backend_module.await(job, opts)
  end

  @doc "Check backend health"
  def health do
    backend().health()
  end

  @doc "Cancel a running job"
  def cancel(job_id) when is_binary(job_id) do
    backend().cancel(job_id)
  end

  @doc "Get current backend capabilities"
  def capabilities do
    if function_exported?(backend(), :capabilities, 0) do
      backend().capabilities()
    else
      []
    end
  end

  @doc "Get the configured backend module"
  def backend do
    backend_name = config()[:backend] || :local
    @backends[backend_name] || raise "Unknown backend: #{backend_name}"
  end

  @doc "Get the configured timeout in milliseconds"
  def timeout do
    config()[:timeout_ms] || 1_200_000
  end

  @doc "Get the full docling config"
  def config do
    Application.get_env(:lumainus, :docling, [])
  end

  defp merge_opts(opts) do
    Keyword.put_new(opts, :timeout_ms, timeout())
  end
end
```

### 5. Vast.ai Instance Manager

```elixir
# lib/lumainus/docling/vast_ai/instance_manager.ex
defmodule Lumainus.Docling.VastAI.InstanceManager do
  @moduledoc """
  Manages Vast.ai GPU instance lifecycle.

  - Provisions instances on-demand
  - Monitors health
  - Destroys idle instances
  - Tracks active instance endpoint
  """

  use GenServer
  require Logger

  @idle_timeout_ms 15 * 60 * 1000  # 15 minutes

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Ensure an instance is running and return its endpoint"
  def ensure_instance do
    GenServer.call(__MODULE__, :ensure_instance, 120_000)
  end

  @doc "Get current instance endpoint if available"
  def get_endpoint do
    GenServer.call(__MODULE__, :get_endpoint)
  end

  @doc "Get current instance ID"
  def current_instance_id do
    GenServer.call(__MODULE__, :current_instance_id)
  end

  @doc "Destroy current instance"
  def destroy_instance do
    GenServer.call(__MODULE__, :destroy_instance)
  end

  # GenServer implementation

  def init(_opts) do
    {:ok, %{
      instance_id: nil,
      endpoint: nil,
      last_activity: nil,
      provisioning: false
    }}
  end

  def handle_call(:ensure_instance, _from, %{endpoint: endpoint} = state) when not is_nil(endpoint) do
    state = %{state | last_activity: System.monotonic_time(:millisecond)}
    {:reply, {:ok, endpoint}, state}
  end

  def handle_call(:ensure_instance, _from, state) do
    case provision_instance() do
      {:ok, instance_id, endpoint} ->
        state = %{state |
          instance_id: instance_id,
          endpoint: endpoint,
          last_activity: System.monotonic_time(:millisecond)
        }
        schedule_idle_check()
        {:reply, {:ok, endpoint}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_endpoint, _from, state) do
    case state.endpoint do
      nil -> {:reply, {:error, :no_instance}, state}
      endpoint -> {:reply, {:ok, endpoint}, state}
    end
  end

  def handle_call(:current_instance_id, _from, state) do
    {:reply, state.instance_id, state}
  end

  def handle_call(:destroy_instance, _from, state) do
    if state.instance_id do
      destroy_vast_instance(state.instance_id)
    end
    {:reply, :ok, %{state | instance_id: nil, endpoint: nil}}
  end

  def handle_info(:check_idle, state) do
    now = System.monotonic_time(:millisecond)
    idle_time = now - (state.last_activity || now)

    if idle_time > @idle_timeout_ms and state.instance_id do
      Logger.info("[VastAI] Destroying idle instance #{state.instance_id}")
      destroy_vast_instance(state.instance_id)
      {:noreply, %{state | instance_id: nil, endpoint: nil}}
    else
      schedule_idle_check()
      {:noreply, state}
    end
  end

  defp schedule_idle_check do
    Process.send_after(self(), :check_idle, 60_000)
  end

  defp provision_instance do
    # Call Python vast_manager.py or implement in Elixir
    # This would use the Vast.ai API to:
    # 1. Search for available RTX 3090 instances
    # 2. Rent the cheapest one
    # 3. Wait for it to be ready
    # 4. Return the endpoint

    # For now, delegate to Python script
    config = Application.get_env(:lumainus, :docling, [])[:vast_ai] || []

    case System.cmd("python3", [
      "docling_service/manage_vast.py",
      "provision"
    ], env: [{"VAST_API_KEY", config[:api_key] || ""}]) do
      {output, 0} ->
        # Parse endpoint from output
        parse_provision_output(output)
      {error, _} ->
        {:error, {:provision_failed, error}}
    end
  end

  defp destroy_vast_instance(instance_id) do
    System.cmd("python3", [
      "docling_service/manage_vast.py",
      "destroy",
      to_string(instance_id)
    ])
  end

  defp parse_provision_output(output) do
    # Parse "Instance ID: 123\nEndpoint: http://..." format
    # ...
    {:ok, "12345", "http://1.2.3.4:8042"}
  end
end
```

---

## Configuration

### Development (default)

```elixir
# config/dev.exs
config :lumainus, :docling,
  backend: :local,
  timeout_ms: 1_200_000,
  local_url: "http://127.0.0.1:8042",
  poll_interval_ms: 5_000
```

### Production with Remote GPU

```elixir
# config/prod.exs
config :lumainus, :docling,
  backend: :remote,
  timeout_ms: 1_200_000,
  remote_url: System.get_env("DOCLING_URL"),
  poll_interval_ms: 5_000
```

### Production with Vast.ai (On-Demand)

```elixir
# config/prod.exs
config :lumainus, :docling,
  backend: :vast_ai,
  timeout_ms: 1_200_000,
  poll_interval_ms: 5_000,
  vast_ai: [
    api_key: System.get_env("VAST_API_KEY"),
    gpu_name: "RTX_3090",
    min_disk_gb: 20,
    idle_timeout_minutes: 15
  ]
```

### Test

```elixir
# config/test.exs
config :lumainus, :docling,
  backend: :local,
  timeout_ms: 30_000,
  local_url: "http://127.0.0.1:8042"
```

---

## Migration Path

### Phase 1: Extract HTTP Client (Low Risk)

1. Create `Lumainus.Docling.HTTP` module
2. Move all HTTP logic from `Docling` and `Docling.Queue`
3. Update existing modules to delegate to HTTP
4. No behavior change - just refactoring

### Phase 2: Add Backend Behaviour (Medium Risk)

1. Create `Lumainus.Docling.Backend` behaviour
2. Create `Backends.Local` implementing the behaviour
3. Update `Docling` façade to use backend
4. Test thoroughly

### Phase 3: Add Remote Backend (Low Risk)

1. Create `Backends.Remote` (nearly identical to Local)
2. Add `:remote_url` config option
3. Test with actual remote endpoint

### Phase 4: Add Vast.ai Backend (Higher Risk)

1. Create `Backends.VastAI`
2. Create `VastAI.InstanceManager` GenServer
3. Add to supervision tree
4. Integrate Python scripts or rewrite in Elixir
5. Add cost monitoring

---

## Usage Examples

### Simple Conversion (Any Backend)

```elixir
# The backend is selected automatically based on config
{:ok, result} = Lumainus.Docling.convert(pdf_binary, filename: "report.pdf")
markdown = result["markdown"]
```

### Async with Progress Tracking

```elixir
{:ok, job} = Lumainus.Docling.enqueue(pdf_binary,
  filename: "large_report.pdf",
  job_id: my_job_id
)

{:ok, result} = Lumainus.Docling.await(job,
  on_status: fn status ->
    progress = status["progress"]
    Logger.info("Conversion at #{progress}%")
  end
)
```

### Check Backend Capabilities

```elixir
caps = Lumainus.Docling.capabilities()
# [:sync, :async, :sse, :cancel, :auto_provision, :gpu]

if :gpu in caps do
  Logger.info("Using GPU acceleration")
end
```

### Force Specific Backend (Testing)

```elixir
# In test setup
Application.put_env(:lumainus, :docling, backend: :local)

# Or use a mock backend
defmodule MockBackend do
  @behaviour Lumainus.Docling.Backend
  # ... implement with mocks
end
```

---

## Benefits of This Design

1. **Clean Separation**: Backend selection is configuration, not code
2. **Easy Testing**: Can mock backend or use local for all tests
3. **Future Proof**: Easy to add new backends (Lambda, Kubernetes, etc.)
4. **Consistent API**: Same interface regardless of where Docling runs
5. **Observable**: All backends use same progress reporting
6. **Elixir Idioms**: Uses behaviours, GenServers, supervision trees

---

## Open Questions

1. **Instance Pooling**: Should Vast.ai backend support multiple instances for parallelism?
2. **Fallback Chain**: Should we try local → remote → vast_ai automatically?
3. **Cost Limits**: How to enforce spending limits on Vast.ai?
4. **Caching**: Should we cache results by PDF hash?

---

## File References

The following files are relevant context for this design:

### Core Documentation
- `README.md` - Project overview, setup instructions, architecture
- `AGENTS.md` - AI agent instructions, code style, design philosophy

### Current Implementation
- `lib/lumainus/docling.ex` - Current Docling client (lines 1-175)
- `lib/lumainus/docling/queue.ex` - Queue abstraction with SSE/polling (lines 1-215)
- `lib/lumainus/documents/ingestion_processor.ex` - Main consumer of Docling API

### Configuration
- `config/config.exs` - Current Docling config (lines 27-44)

### Previous Design Docs
- `docs/20251121/VAST_AI_INTEGRATION_PLAN_refined.md` - Vast.ai deployment design
- `docs/20251121/CONCURRENCY_ARCH_DOCLING.md` - Concurrency analysis
- `docs/20251121/ingestion_queue_system_design.md` - Queue architecture
- `docs/CONTINUATION_PROMPT.md` - Pending work items

---

## Next Steps

1. Review this design with stakeholders
2. Decide on Phase 1 scope (HTTP extraction)
3. Create implementation branch
4. Write tests for Backend behaviour
5. Iterate on Vast.ai instance management

---

**End of Design Document**
