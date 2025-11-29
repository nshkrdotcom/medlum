# Simplified Docling Architecture

**Date:** November 28, 2025
**Goal:** Two backends, zero manual intervention, seamless UX

---

## Design Principles

1. **Two options only**: Local OR Cloud (not five backends)
2. **Transparent to users**: "Upload PDF, get result" - no GPU/backend knowledge needed
3. **Zero manual intervention**: Deploy and forget
4. **Single source of truth**: One config, one state, one UI
5. **Real-time feedback**: Users see progress, errors immediately

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         USER INTERFACE                          │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │              PDF Upload Page (NEW)                       │  │
│   │   - Drag & drop files                                    │  │
│   │   - Real-time progress bar                               │  │
│   │   - "Processing..." → "Complete!" states                 │  │
│   │   - No backend selection (automatic)                     │  │
│   └─────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     BACKEND ROUTER (NEW)                        │
│                                                                 │
│   get_endpoint() → Check mode → Return active endpoint          │
│                                                                 │
│   Mode: "local"  → LocalManager.ensure_running()               │
│   Mode: "cloud"  → CloudManager.ensure_running()               │
└─────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
┌──────────────────────────┐    ┌──────────────────────────┐
│     LOCAL MANAGER        │    │     CLOUD MANAGER        │
│                          │    │                          │
│ - Auto-start Docker      │    │ - Auto-provision Vast.ai │
│ - Health monitoring      │    │ - Auto-start stopped     │
│ - Auto-restart on crash  │    │ - Auto-stop on idle      │
│ - One endpoint: :8042    │    │ - Health monitoring      │
└──────────────────────────┘    └──────────────────────────┘
              │                               │
              ▼                               ▼
┌──────────────────────────┐    ┌──────────────────────────┐
│   Docker Container       │    │   Vast.ai GPU Instance   │
│   docling:latest         │    │   RTX 4090               │
│   Port 8042              │    │   HTTPS endpoint         │
└──────────────────────────┘    └──────────────────────────┘
```

---

## Component Specifications

### 1. Simplified Settings Schema

**File:** `lib/lumainus/docling/settings.ex` (REWRITE)

```elixir
defmodule Lumainus.Docling.Settings do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "docling_settings" do
    # === CORE SETTINGS (Only these matter) ===
    field :mode, :string, default: "local"  # "local" | "cloud"

    # === LOCAL SETTINGS ===
    field :local_endpoint, :string, default: "http://127.0.0.1:8042"
    field :local_gpu_enabled, :boolean, default: false
    field :local_auto_manage, :boolean, default: true  # Auto-start Docker

    # === CLOUD SETTINGS ===
    field :cloud_api_key, :string  # Vast.ai API key
    field :cloud_auto_provision, :boolean, default: true  # Provision on demand
    field :cloud_idle_timeout_minutes, :integer, default: 15
    field :cloud_max_price_per_hour, :decimal, default: Decimal.new("0.50")

    # === PROCESSING SETTINGS ===
    field :timeout_ms, :integer, default: 300_000  # 5 minutes (not 20!)
    field :max_file_size_mb, :integer, default: 100

    timestamps()
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :mode,
      :local_endpoint, :local_gpu_enabled, :local_auto_manage,
      :cloud_api_key, :cloud_auto_provision, :cloud_idle_timeout_minutes,
      :cloud_max_price_per_hour,
      :timeout_ms, :max_file_size_mb
    ])
    |> validate_required([:mode, :timeout_ms])
    |> validate_inclusion(:mode, ["local", "cloud"])
    |> validate_number(:timeout_ms, greater_than: 0, less_than: 600_000)
    |> validate_cloud_requirements()
  end

  defp validate_cloud_requirements(changeset) do
    if get_field(changeset, :mode) == "cloud" do
      validate_required(changeset, [:cloud_api_key])
    else
      changeset
    end
  end
end
```

**Changes from current:**
- Reduced from 20+ fields to 10
- No more 5 backend URLs
- No more v2_profile_backends
- No more legacy fields
- Timeout reduced from 20 min to 5 min

---

### 2. Local Manager (Auto-Managed Docker)

**File:** `lib/lumainus/backends/local_manager.ex` (NEW)

```elixir
defmodule Lumainus.Backends.LocalManager do
  @moduledoc """
  Manages local Docker Docling container.
  Auto-starts on app boot, auto-restarts on failure.
  """
  use GenServer
  require Logger

  @health_check_interval_ms 30_000
  @startup_timeout_ms 60_000
  @container_name "lumainus-docling"

  defstruct [:endpoint, :status, :container_id, :last_health_check]

  # === PUBLIC API ===

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_endpoint do
    GenServer.call(__MODULE__, :get_endpoint)
  end

  def ensure_running do
    GenServer.call(__MODULE__, :ensure_running, @startup_timeout_ms)
  end

  def health do
    GenServer.call(__MODULE__, :health, 5_000)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  # === GENSERVER CALLBACKS ===

  @impl true
  def init(_opts) do
    settings = Lumainus.Docling.Settings.get()

    state = %__MODULE__{
      endpoint: settings.local_endpoint,
      status: :unknown,
      container_id: nil,
      last_health_check: nil
    }

    # Auto-start if configured
    if settings.local_auto_manage and settings.mode == "local" do
      send(self(), :ensure_container_running)
    end

    # Start health check loop
    schedule_health_check()

    {:ok, state}
  end

  @impl true
  def handle_call(:get_endpoint, _from, state) do
    {:reply, {:ok, state.endpoint}, state}
  end

  @impl true
  def handle_call(:ensure_running, _from, state) do
    case do_ensure_running(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.endpoint}, new_state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:health, _from, state) do
    result = check_health(state.endpoint)
    {:reply, result, %{state | last_health_check: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_info(:ensure_container_running, state) do
    case do_ensure_running(state) do
      {:ok, new_state} ->
        Logger.info("[LocalManager] Container running: #{new_state.container_id}")
        broadcast_status(:healthy)
        {:noreply, new_state}
      {:error, reason} ->
        Logger.error("[LocalManager] Failed to start container: #{inspect(reason)}")
        broadcast_status(:unhealthy)
        # Retry in 30 seconds
        Process.send_after(self(), :ensure_container_running, 30_000)
        {:noreply, %{state | status: :error}}
    end
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state = case check_health(state.endpoint) do
      :ok ->
        broadcast_status(:healthy)
        %{state | status: :healthy, last_health_check: DateTime.utc_now()}
      {:error, _reason} ->
        broadcast_status(:unhealthy)
        # Try to restart container
        send(self(), :ensure_container_running)
        %{state | status: :unhealthy}
    end

    schedule_health_check()
    {:noreply, new_state}
  end

  # === PRIVATE FUNCTIONS ===

  defp do_ensure_running(state) do
    with :ok <- ensure_docker_available(),
         {:ok, container_id} <- ensure_container_exists(),
         :ok <- ensure_container_started(container_id),
         :ok <- wait_for_healthy(state.endpoint) do
      {:ok, %{state | status: :healthy, container_id: container_id}}
    end
  end

  defp ensure_docker_available do
    case System.cmd("docker", ["info"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, {:docker_unavailable, output}}
    end
  end

  defp ensure_container_exists do
    settings = Lumainus.Docling.Settings.get()
    image = if settings.local_gpu_enabled, do: "docling:gpu", else: "docling:cpu"

    # Check if container exists
    case System.cmd("docker", ["ps", "-a", "-q", "-f", "name=#{@container_name}"]) do
      {"", 0} ->
        # Container doesn't exist, create it
        create_container(image, settings)
      {container_id, 0} ->
        {:ok, String.trim(container_id)}
      {_, code} ->
        {:error, {:docker_error, code}}
    end
  end

  defp create_container(image, settings) do
    port = URI.parse(settings.local_endpoint).port || 8042

    gpu_args = if settings.local_gpu_enabled do
      ["--gpus", "all"]
    else
      []
    end

    args = [
      "run", "-d",
      "--name", @container_name,
      "-p", "#{port}:8000",
      "--restart", "unless-stopped"
    ] ++ gpu_args ++ [image]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {container_id, 0} -> {:ok, String.trim(container_id)}
      {output, _} -> {:error, {:container_create_failed, output}}
    end
  end

  defp ensure_container_started(container_id) do
    case System.cmd("docker", ["start", container_id]) do
      {_, 0} -> :ok
      {output, _} -> {:error, {:container_start_failed, output}}
    end
  end

  defp wait_for_healthy(endpoint, attempts \\ 30) do
    if attempts <= 0 do
      {:error, :timeout_waiting_for_healthy}
    else
      case check_health(endpoint) do
        :ok -> :ok
        {:error, _} ->
          Process.sleep(2_000)
          wait_for_healthy(endpoint, attempts - 1)
      end
    end
  end

  defp check_health(endpoint) do
    url = "#{endpoint}/health"
    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:unhealthy, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval_ms)
  end

  defp broadcast_status(status) do
    Phoenix.PubSub.broadcast(
      LumainusWeb.PubSub,
      "docling:status",
      {:docling_status, :local, status}
    )
  end
end
```

**Key Features:**
- Auto-starts Docker container on app boot
- Auto-restarts on container crash
- Waits for healthy before returning endpoint
- Single container name (no port conflicts)
- GPU toggle via settings
- Broadcasts status changes to UI

---

### 3. Cloud Manager (True Auto-Boot)

**File:** `lib/lumainus/backends/cloud_manager.ex` (NEW)

```elixir
defmodule Lumainus.Backends.CloudManager do
  @moduledoc """
  Manages Vast.ai cloud GPU instance.
  True auto-provision: Creates instance on first request if none exists.
  """
  use GenServer
  require Logger

  @health_check_interval_ms 30_000
  @idle_check_interval_ms 300_000  # 5 minutes
  @provision_timeout_ms 300_000    # 5 minutes to provision

  defstruct [
    :endpoint,
    :status,
    :instance_id,
    :last_activity,
    :last_health_check,
    :provisioning?
  ]

  # === PUBLIC API ===

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_endpoint do
    GenServer.call(__MODULE__, :get_endpoint, 10_000)
  end

  def ensure_running do
    GenServer.call(__MODULE__, :ensure_running, @provision_timeout_ms)
  end

  def health do
    GenServer.call(__MODULE__, :health, 10_000)
  end

  def record_activity do
    GenServer.cast(__MODULE__, :record_activity)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  # === GENSERVER CALLBACKS ===

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      endpoint: nil,
      status: :unknown,
      instance_id: nil,
      last_activity: nil,
      last_health_check: nil,
      provisioning?: false
    }

    # Check for existing instance on startup
    send(self(), :sync_with_vastai)

    # Start idle check loop
    schedule_idle_check()

    {:ok, state}
  end

  @impl true
  def handle_call(:get_endpoint, _from, %{endpoint: nil} = state) do
    {:reply, {:error, :no_instance}, state}
  end

  def handle_call(:get_endpoint, _from, state) do
    {:reply, {:ok, state.endpoint}, state}
  end

  @impl true
  def handle_call(:ensure_running, _from, %{status: :running} = state) do
    {:reply, {:ok, state.endpoint}, state}
  end

  def handle_call(:ensure_running, _from, %{provisioning?: true} = state) do
    # Already provisioning, wait for it
    {:reply, {:error, :provisioning_in_progress}, state}
  end

  def handle_call(:ensure_running, _from, state) do
    case do_ensure_running(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.endpoint}, new_state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:health, _from, state) do
    result = if state.endpoint, do: check_health(state.endpoint), else: {:error, :no_endpoint}
    {:reply, result, %{state | last_health_check: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  def handle_cast(:record_activity, state) do
    {:noreply, %{state | last_activity: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(:sync_with_vastai, state) do
    settings = Lumainus.Docling.Settings.get()

    if settings.mode == "cloud" and settings.cloud_api_key do
      case VastAI.list_instances(settings.cloud_api_key) do
        {:ok, [instance | _]} ->
          new_state = recover_instance(state, instance)
          broadcast_status(new_state.status)
          {:noreply, new_state}
        {:ok, []} ->
          Logger.info("[CloudManager] No existing instances found")
          {:noreply, %{state | status: :none}}
        {:error, reason} ->
          Logger.error("[CloudManager] Failed to sync: #{inspect(reason)}")
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:idle_check, state) do
    settings = Lumainus.Docling.Settings.get()
    idle_timeout = settings.cloud_idle_timeout_minutes * 60

    new_state = if should_stop_for_idle?(state, idle_timeout) do
      Logger.info("[CloudManager] Stopping idle instance")
      stop_instance(state)
    else
      state
    end

    schedule_idle_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state = if state.endpoint do
      case check_health(state.endpoint) do
        :ok ->
          broadcast_status(:healthy)
          %{state | status: :running, last_health_check: DateTime.utc_now()}
        {:error, _} ->
          broadcast_status(:unhealthy)
          %{state | status: :unhealthy}
      end
    else
      state
    end

    schedule_health_check()
    {:noreply, new_state}
  end

  # === PRIVATE FUNCTIONS ===

  defp do_ensure_running(%{instance_id: nil} = state) do
    # No instance exists, provision one
    settings = Lumainus.Docling.Settings.get()

    if settings.cloud_auto_provision do
      provision_new_instance(state, settings)
    else
      {:error, :no_instance_and_auto_provision_disabled}
    end
  end

  defp do_ensure_running(%{status: :stopped} = state) do
    # Instance exists but stopped, start it
    start_instance(state)
  end

  defp do_ensure_running(state) do
    # Instance running or unknown, check health
    case check_health(state.endpoint) do
      :ok -> {:ok, %{state | status: :running}}
      {:error, _} -> start_instance(state)
    end
  end

  defp provision_new_instance(state, settings) do
    Logger.info("[CloudManager] Provisioning new Vast.ai instance...")

    opts = [
      gpu: "RTX_4090",
      disk_gb: 20,
      max_price: Decimal.to_float(settings.cloud_max_price_per_hour),
      image: "ghcr.io/.../docling:gpu"
    ]

    case VastAI.provision(settings.cloud_api_key, opts) do
      {:ok, instance} ->
        new_state = %{state |
          instance_id: instance.id,
          endpoint: instance.endpoint,
          status: :running,
          last_activity: DateTime.utc_now(),
          provisioning?: false
        }
        broadcast_status(:running)
        {:ok, new_state}
      {:error, reason} ->
        {:error, {:provision_failed, reason}}
    end
  end

  defp start_instance(%{instance_id: instance_id} = state) do
    settings = Lumainus.Docling.Settings.get()

    case VastAI.start_instance(settings.cloud_api_key, instance_id) do
      {:ok, instance} ->
        new_state = %{state |
          endpoint: instance.endpoint,
          status: :running,
          last_activity: DateTime.utc_now()
        }
        broadcast_status(:running)
        {:ok, new_state}
      {:error, reason} ->
        {:error, {:start_failed, reason}}
    end
  end

  defp stop_instance(%{instance_id: instance_id} = state) do
    settings = Lumainus.Docling.Settings.get()

    case VastAI.stop_instance(settings.cloud_api_key, instance_id) do
      :ok ->
        broadcast_status(:stopped)
        %{state | status: :stopped, endpoint: nil}
      {:error, reason} ->
        Logger.error("[CloudManager] Failed to stop: #{inspect(reason)}")
        state
    end
  end

  defp recover_instance(state, instance) do
    status = case instance.status do
      "running" -> :running
      "stopped" -> :stopped
      _ -> :unknown
    end

    %{state |
      instance_id: instance.id,
      endpoint: instance.endpoint,
      status: status,
      last_activity: DateTime.utc_now()
    }
  end

  defp should_stop_for_idle?(state, idle_timeout_seconds) do
    state.status == :running and
    state.last_activity != nil and
    DateTime.diff(DateTime.utc_now(), state.last_activity) > idle_timeout_seconds
  end

  defp check_health(endpoint) do
    url = "#{endpoint}/health"
    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:unhealthy, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_idle_check do
    Process.send_after(self(), :idle_check, @idle_check_interval_ms)
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval_ms)
  end

  defp broadcast_status(status) do
    Phoenix.PubSub.broadcast(
      LumainusWeb.PubSub,
      "docling:status",
      {:docling_status, :cloud, status}
    )
  end
end
```

**Key Features:**
- TRUE auto-provision: Creates instance on first request
- Auto-start stopped instances
- Auto-stop on idle timeout
- Syncs with Vast.ai on app boot
- Price limit enforcement
- Broadcasts status changes

---

### 4. Unified Backend Router

**File:** `lib/lumainus/backends/router.ex` (NEW)

```elixir
defmodule Lumainus.Backends.Router do
  @moduledoc """
  Single entry point for backend selection.
  No profiles, no complexity - just get an endpoint.
  """

  alias Lumainus.Backends.{LocalManager, CloudManager}
  alias Lumainus.Docling.Settings

  @doc """
  Get an endpoint for PDF processing.
  Automatically ensures the backend is running.
  """
  def get_endpoint(opts \\ []) do
    settings = Settings.get()
    force_cloud = Keyword.get(opts, :force_cloud, false)

    mode = if force_cloud, do: "cloud", else: settings.mode

    case mode do
      "local" -> get_local_endpoint()
      "cloud" -> get_cloud_endpoint()
    end
  end

  defp get_local_endpoint do
    case LocalManager.health() do
      :ok ->
        LocalManager.get_endpoint()
      {:error, _} ->
        case LocalManager.ensure_running() do
          {:ok, endpoint} -> {:ok, endpoint}
          {:error, reason} -> {:error, {:local_unavailable, reason}}
        end
    end
  end

  defp get_cloud_endpoint do
    case CloudManager.health() do
      :ok ->
        CloudManager.record_activity()
        CloudManager.get_endpoint()
      {:error, _} ->
        case CloudManager.ensure_running() do
          {:ok, endpoint} ->
            CloudManager.record_activity()
            {:ok, endpoint}
          {:error, reason} ->
            {:error, {:cloud_unavailable, reason}}
        end
    end
  end
end
```

**Key Features:**
- One function: `get_endpoint()`
- No profiles, no backend selection complexity
- Automatic health check and recovery
- Force cloud option for premium users

---

## Files to Delete (Cleanup)

After implementing the new architecture, these files should be removed:

```
lib/lumainus/docling/
├── setting.ex              # REWRITE (simplified)
├── settings.ex             # MERGE into new settings
├── health_manager.ex       # DELETE (replaced by LocalManager/CloudManager)
├── vast_ai/
│   ├── instance_manager.ex # DELETE (1487 lines → 200 in CloudManager)
│   ├── activity_tracker.ex # DELETE (built into CloudManager)
│   ├── start_tracker.ex    # DELETE (not needed)
│   ├── auto_shutdown.ex    # DELETE (built into CloudManager)
│   └── provisioning_state.ex # DELETE (not needed)

lib/lumainus/conversion/
├── backend_router.ex       # DELETE (replaced by backends/router.ex)
├── processing_profile.ex   # DELETE (profiles removed)
└── circuit_breaker.ex      # SIMPLIFY (one breaker per mode)
```

**Estimated line reduction:** ~3,000 lines removed

---

## Configuration Comparison

### Before (Current System)
```elixir
# 20+ configuration options
config :lumainus, :docling,
  default_mode: :local,
  active_local_backend: :docker_cpu,
  native_cpu_url: "http://127.0.0.1:8040",
  native_gpu_url: "http://127.0.0.1:8041",
  docker_cpu_url: "http://127.0.0.1:8042",
  docker_gpu_url: "http://127.0.0.1:8043",
  cloud_url: "https://...",
  v2_profile_backends: %{...},
  timeout_ms: 1_200_000,
  # ... etc
```

### After (New System)
```elixir
# 10 configuration options
config :lumainus, :docling,
  mode: "local",  # or "cloud"
  local_endpoint: "http://127.0.0.1:8042",
  local_gpu_enabled: false,
  local_auto_manage: true,
  cloud_api_key: System.get_env("VASTAI_API_KEY"),
  cloud_auto_provision: true,
  cloud_idle_timeout_minutes: 15,
  cloud_max_price_per_hour: 0.50,
  timeout_ms: 300_000,
  max_file_size_mb: 100
```

---

## Summary

| Aspect | Before | After |
|--------|--------|-------|
| Backends | 5 | 2 |
| Config fields | 20+ | 10 |
| GenServer processes | 5+ | 2 |
| Health checks/30s | 4-5 | 1 |
| Code lines | ~4000 | ~800 |
| Manual steps | Many | Zero |
| User complexity | Profiles, backends | None |
| Admin complexity | 5 URLs, modes | 1 toggle |

See `03-NEW-UPLOAD-PAGE.md` for the user-facing design.
