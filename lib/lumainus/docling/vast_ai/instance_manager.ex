defmodule Lumainus.Docling.VastAI.InstanceManager do
  @moduledoc """
  Manages Vast.ai GPU instance lifecycle.

  - Provisions instances on-demand
  - Monitors health
  - Destroys idle instances
  - Tracks active instance endpoint

  ## Configuration

      config :lumainus, :docling,
        vast_ai: [
          api_key: "...",
          gpu_name: "RTX_3090",
          min_disk_gb: 20,
          idle_timeout_minutes: 15
        ]

  ## Usage

      # Get or provision an instance
      {:ok, endpoint} = InstanceManager.ensure_instance()

      # Update activity (resets idle timer)
      :ok = InstanceManager.update_activity()

      # Destroy instance
      :ok = InstanceManager.destroy_instance()
  """

  use GenServer
  require Logger

  alias Lumainus.GPU
  alias Lumainus.VastAI
  @compile {:no_warn_undefined, Lumainus.VastAI}

  @idle_check_interval_ms 60_000

  # =============================================================================
  # Public API
  # =============================================================================

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Ensure an instance is running and return its endpoint.

  If no instance exists, provisions a new one. Otherwise returns the cached endpoint.
  """
  def ensure_instance(server \\ __MODULE__) do
    GenServer.call(server, :ensure_instance, 120_000)
  end

  @doc """
  Get current instance endpoint if available.
  """
  def get_endpoint(server \\ __MODULE__) do
    GenServer.call(server, :get_endpoint)
  end

  @doc """
  Get current instance ID.
  """
  def current_instance_id(server \\ __MODULE__) do
    GenServer.call(server, :current_instance_id)
  end

  @doc """
  Destroy current instance.
  """
  def destroy_instance(server \\ __MODULE__) do
    GenServer.call(server, :destroy_instance)
  end

  @doc """
  Update last activity timestamp (resets idle timer).
  """
  def update_activity(server \\ __MODULE__) do
    GenServer.cast(server, :update_activity)
  end

  @doc """
  Set the instance endpoint from external provisioning (e.g., auto_provision_gpu).

  This is called when provisioning happens through a different code path
  to ensure InstanceManager knows about the instance and doesn't try to
  provision a duplicate.
  """
  def set_endpoint(instance_id, endpoint, server \\ __MODULE__) do
    GenServer.call(server, {:set_endpoint, instance_id, endpoint})
  end

  @doc """
  Check if there's already a running instance (either in our state or on Vast.ai).

  Returns:
    - {:ok, endpoint} if we already have an endpoint tracked
    - {:ok, :running, instance_id} if Vast.ai has a running instance we don't track
    - {:ok, :none} if no instance exists
    - {:error, reason} on API failure
  """
  def check_existing_instance(server \\ __MODULE__) do
    GenServer.call(server, :check_existing_instance, 30_000)
  end

  @doc """
  Sync local state with Vast.ai reality.

  This handles cases where instances are deleted externally (via Vast.ai console)
  or where the app restarted and lost track of a running instance.

  Returns:
    - {:ok, :synced, endpoint} if we found and adopted a running instance
    - {:ok, :cleared} if our cached instance was stale and we cleared state
    - {:ok, :unchanged} if state already matches reality
    - {:error, reason} on API failure
  """
  def sync_with_vast_ai(server \\ __MODULE__) do
    GenServer.call(server, :sync_with_vast_ai, 30_000)
  end

  @doc """
  Clear the cached endpoint state.

  Used when we know the instance is gone (e.g., after deletion).
  """
  def clear_state(server \\ __MODULE__) do
    GenServer.call(server, :clear_state)
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def init(_opts) do
    # Schedule a sync with Vast.ai shortly after startup
    # This handles app restarts where we lost track of a running instance
    Process.send_after(self(), :startup_sync, 1_000)

    {:ok,
     %{
       instance_id: nil,
       endpoint: nil,
       last_activity: nil,
       provisioning: false
     }}
  end

  @impl true
  def handle_call(:ensure_instance, _from, %{endpoint: endpoint} = state)
      when not is_nil(endpoint) do
    state = %{state | last_activity: System.monotonic_time(:millisecond)}
    {:reply, {:ok, endpoint}, state}
  end

  def handle_call(:ensure_instance, _from, state) do
    # SAFETY: First check if there's already a running instance on Vast.ai
    # This handles the case where our state was lost (e.g., server restart)
    case check_vast_ai_for_running_instances() do
      {:ok, instance_id, ip} when is_binary(ip) and ip != "" ->
        # Found existing instance - recover it instead of provisioning new one
        Logger.info("[InstanceManager] Recovering existing instance #{instance_id} at #{ip}")

        # Build endpoint from the FQDN (for HTTPS) or IP (for HTTP fallback)
        endpoint = recover_endpoint(ip)

        GPU.log(:lifecycle, :instance_recovered, "Recovered existing Vast.ai instance",
          instance_id: instance_id,
          endpoint: endpoint,
          source: "instance_manager"
        )

        state = %{
          state
          | instance_id: instance_id,
            endpoint: endpoint,
            last_activity: System.monotonic_time(:millisecond)
        }

        schedule_idle_check()
        {:reply, {:ok, endpoint}, state}

      {:ok, instance_id, nil} ->
        # Instance exists but no IP yet - it may still be loading
        Logger.warning(
          "[InstanceManager] Found instance #{instance_id} but no IP - may still be loading"
        )

        {:reply, {:error, {:instance_loading, instance_id}}, state}

      {:ok, :none} ->
        # No existing instance - proceed with provisioning
        case provision_instance() do
          {:ok, instance_id, endpoint} ->
            state = %{
              state
              | instance_id: instance_id,
                endpoint: endpoint,
                last_activity: System.monotonic_time(:millisecond)
            }

            schedule_idle_check()
            {:reply, {:ok, endpoint}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        # API error - can't check, don't provision blindly
        Logger.error(
          "[InstanceManager] Failed to check for existing instances: #{inspect(reason)}"
        )

        {:reply, {:error, {:api_check_failed, reason}}, state}
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
      GPU.log(:lifecycle, :destroy_requested, "Instance destruction requested",
        instance_id: state.instance_id,
        source: "instance_manager"
      )

      destroy_vast_instance(state.instance_id, "manual")
    end

    {:reply, :ok, %{state | instance_id: nil, endpoint: nil, last_activity: nil}}
  end

  def handle_call({:set_endpoint, instance_id, endpoint}, _from, state) do
    Logger.info(
      "[InstanceManager] Setting endpoint from external provisioning: #{instance_id} -> #{endpoint}"
    )

    GPU.log(:lifecycle, :endpoint_set, "Instance endpoint set from external provisioning",
      instance_id: instance_id,
      endpoint: endpoint,
      source: "instance_manager"
    )

    state = %{
      state
      | instance_id: instance_id,
        endpoint: endpoint,
        last_activity: System.monotonic_time(:millisecond)
    }

    schedule_idle_check()
    {:reply, :ok, state}
  end

  def handle_call(:check_existing_instance, _from, state) do
    # First check our own state
    if state.endpoint do
      {:reply, {:ok, state.endpoint}, state}
    else
      # Check Vast.ai API for running instances
      case check_vast_ai_for_running_instances() do
        {:ok, :none} ->
          {:reply, {:ok, :none}, state}

        {:ok, instance_id, _ip} ->
          {:reply, {:ok, :running, instance_id}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(:sync_with_vast_ai, _from, state) do
    Logger.info("[InstanceManager] Syncing state with Vast.ai...")

    case check_vast_ai_for_running_instances() do
      {:ok, :none} ->
        # No running instances on Vast.ai
        if state.instance_id do
          # Our cached instance is stale - clear it
          Logger.warning(
            "[InstanceManager] Cached instance #{state.instance_id} no longer exists on Vast.ai, clearing state"
          )

          GPU.log(
            :lifecycle,
            :state_cleared,
            "Cleared stale instance state - instance no longer exists on Vast.ai",
            instance_id: state.instance_id,
            source: "instance_manager"
          )

          {:reply, {:ok, :cleared},
           %{state | instance_id: nil, endpoint: nil, last_activity: nil}}
        else
          # State already clear
          {:reply, {:ok, :unchanged}, state}
        end

      {:ok, instance_id, ip} when is_binary(ip) and ip != "" ->
        if state.instance_id == instance_id and state.endpoint do
          # Already tracking this instance
          {:reply, {:ok, :unchanged}, state}
        else
          # Found a running instance - adopt it
          endpoint = recover_endpoint(ip)
          Logger.info("[InstanceManager] Adopting running instance #{instance_id} at #{endpoint}")

          GPU.log(:lifecycle, :instance_adopted, "Adopted existing Vast.ai instance",
            instance_id: instance_id,
            endpoint: endpoint,
            source: "instance_manager"
          )

          new_state = %{
            state
            | instance_id: instance_id,
              endpoint: endpoint,
              last_activity: System.monotonic_time(:millisecond)
          }

          schedule_idle_check()
          {:reply, {:ok, :synced, endpoint}, new_state}
        end

      {:ok, instance_id, nil} ->
        # Instance exists but no IP (still loading)
        Logger.info("[InstanceManager] Found instance #{instance_id} but no IP yet (loading)")
        {:reply, {:ok, :loading, instance_id}, state}

      {:error, reason} ->
        Logger.error("[InstanceManager] Failed to sync with Vast.ai: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:clear_state, _from, state) do
    Logger.info("[InstanceManager] Clearing state manually")

    if state.instance_id do
      GPU.log(:lifecycle, :state_cleared, "Instance state cleared manually",
        instance_id: state.instance_id,
        source: "instance_manager"
      )
    end

    {:reply, :ok, %{state | instance_id: nil, endpoint: nil, last_activity: nil}}
  end

  @impl true
  def handle_cast(:update_activity, state) do
    {:noreply, %{state | last_activity: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_info(:check_idle, state) do
    now = System.monotonic_time(:millisecond)
    idle_time = now - (state.last_activity || now)
    idle_timeout = idle_timeout_ms()
    idle_minutes = div(idle_time, 60_000)
    timeout_minutes = div(idle_timeout, 60_000)

    if idle_time > idle_timeout and state.instance_id do
      Logger.info(
        "[VastAI] Destroying idle instance #{state.instance_id} (idle for #{idle_minutes} minutes)"
      )

      # Log to database
      GPU.log(:lifecycle, :idle_shutdown, "Instance idle timeout triggered",
        instance_id: state.instance_id,
        severity: "warning",
        source: "instance_manager",
        details: %{
          idle_minutes: idle_minutes,
          timeout_minutes: timeout_minutes
        }
      )

      destroy_vast_instance(state.instance_id, "idle_timeout")
      {:noreply, %{state | instance_id: nil, endpoint: nil, last_activity: nil}}
    else
      schedule_idle_check()
      {:noreply, state}
    end
  end

  def handle_info(:startup_sync, state) do
    Logger.info("[InstanceManager] Running startup sync with Vast.ai...")

    case check_vast_ai_for_running_instances() do
      {:ok, :none} ->
        Logger.info("[InstanceManager] No running instances found on Vast.ai")
        {:noreply, state}

      {:ok, instance_id, ip} when is_binary(ip) and ip != "" ->
        endpoint = recover_endpoint(ip)

        Logger.info(
          "[InstanceManager] Found running instance #{instance_id} at #{endpoint} on startup"
        )

        GPU.log(:lifecycle, :startup_sync, "Recovered instance on startup",
          instance_id: instance_id,
          endpoint: endpoint,
          source: "instance_manager"
        )

        new_state = %{
          state
          | instance_id: instance_id,
            endpoint: endpoint,
            last_activity: System.monotonic_time(:millisecond)
        }

        schedule_idle_check()
        {:noreply, new_state}

      {:ok, instance_id, nil} ->
        Logger.info(
          "[InstanceManager] Found instance #{instance_id} on startup but no IP (still loading)"
        )

        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[InstanceManager] Startup sync failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp schedule_idle_check do
    Process.send_after(self(), :check_idle, @idle_check_interval_ms)
  end

  defp check_vast_ai_for_running_instances do
    alias Lumainus.VastAI.Instances

    case Instances.list() do
      {:ok, %{"instances" => instances}} when is_list(instances) ->
        running =
          Enum.filter(instances, fn inst ->
            inst["actual_status"] in ["running", "loading"] ||
              inst["cur_state"] in ["running", "loading"]
          end)

        case running do
          [] ->
            {:ok, :none}

          [instance | _rest] ->
            instance_id = instance["id"]
            ip = instance["public_ipaddr"]
            {:ok, instance_id, ip}
        end

      {:ok, %{"instances" => %{"id" => id} = instance}} ->
        # Single instance returned as map
        status = instance["actual_status"] || instance["cur_state"]

        if status in ["running", "loading"] do
          {:ok, id, instance["public_ipaddr"]}
        else
          {:ok, :none}
        end

      {:ok, _} ->
        {:ok, :none}

      {:error, reason} ->
        Logger.error("[InstanceManager] Failed to check Vast.ai instances: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp recover_endpoint(ip) do
    # Try to use the HTTPS endpoint via Cloudflare if configured,
    # otherwise fall back to direct HTTP
    fqdn = Lumainus.Cloudflare.cloud_fqdn()

    if fqdn && String.trim(fqdn) != "" do
      # Use HTTPS via Cloudflare (assumes DNS is already pointing to this IP)
      "https://#{fqdn}"
    else
      # Fall back to direct HTTP
      "http://#{ip}:#{Lumainus.VastAI.cloud_port()}"
    end
  end

  defp provision_instance do
    config = vast_ai_config()

    # Check for mock provisioner first (for testing)
    case Keyword.get(config, :provisioner) do
      nil ->
        # Real provisioning via Python script or Elixir HTTP client
        provision_via_api(config)

      provisioner when is_function(provisioner, 0) ->
        provisioner.()
    end
  end

  defp destroy_vast_instance(instance_id, reason) do
    config = vast_ai_config()

    # Check for mock destroyer first (for testing)
    result =
      case Keyword.get(config, :destroyer) do
        nil ->
          # Real destruction via Python script or Elixir HTTP client
          destroy_via_api(instance_id, config)

        destroyer when is_function(destroyer, 1) ->
          destroyer.(instance_id)
      end

    # Log destruction result and update session
    case result do
      :ok ->
        GPU.log(:lifecycle, :instance_destroyed, "Instance destroyed successfully",
          instance_id: instance_id,
          instance_status: "destroyed",
          source: "instance_manager",
          details: %{reason: reason}
        )

        # Update session if exists
        case GPU.get_session_by_instance(instance_id) do
          nil -> :ok
          session -> GPU.destroy_session(session, reason)
        end

      {:error, err} ->
        GPU.log_error(:lifecycle, :destroy_failed, "Failed to destroy instance", err,
          instance_id: instance_id,
          source: "instance_manager"
        )
    end

    result
  end

  defp provision_via_api(config) do
    max_price = Keyword.get(config, :max_price, 0.18)
    disk_gb = Keyword.get(config, :min_disk_gb, 16)
    geo = Keyword.get(config, :geolocation, ["US", "CA"])
    label = Keyword.get(config, :label, "docling-dev")
    use_https = Keyword.get(config, :use_https, true)

    opts = [
      max_price: max_price,
      disk_gb: disk_gb,
      geolocation: geo,
      label: label
    ]

    # Log provisioning start
    GPU.log(:lifecycle, :provision_started, "Instance provisioning started via InstanceManager",
      source: "instance_manager",
      details: %{
        max_price: max_price,
        disk_gb: disk_gb,
        geolocation: geo,
        label: label,
        use_https: use_https
      }
    )

    result =
      if use_https do
        # Provision with Caddy + Let's Encrypt HTTPS
        VastAI.provision_with_https(opts)
      else
        # Legacy HTTP-only provisioning
        with {:ok, instance_id} <- VastAI.provision(opts),
             {:ok, inst} <- VastAI.wait_for_ready(instance_id, 300_000),
             {:ok, endpoint} <- build_endpoint(inst) do
          {:ok, instance_id, endpoint}
        end
      end

    case result do
      {:ok, instance_id, endpoint} ->
        Logger.info("[VastAI] Provisioned instance #{instance_id} at #{endpoint}")

        GPU.log(:lifecycle, :provision_completed, "Instance provisioned successfully",
          instance_id: instance_id,
          endpoint: endpoint,
          instance_status: "ready",
          source: "instance_manager"
        )

        {:ok, instance_id, endpoint}

      {:error, reason} ->
        Logger.error("[VastAI] Provisioning failed: #{inspect(reason)}")

        GPU.log_error(:lifecycle, :provision_failed, "Instance provisioning failed", reason,
          source: "instance_manager"
        )

        {:error, reason}
    end
  end

  defp destroy_via_api(instance_id, _config) do
    Logger.info("[VastAI] Destroying instance #{instance_id}")
    VastAI.destroy(instance_id)
    :ok
  end

  defp build_endpoint(%{"public_ipaddr" => ip}) when is_binary(ip) do
    port = Lumainus.VastAI.cloud_port()
    {:ok, "http://#{ip}:#{port}"}
  end

  defp build_endpoint(_), do: {:error, :no_ip}

  defp vast_ai_config do
    Application.get_env(:lumainus, :docling, [])
    |> Keyword.get(:vast_ai, [])
  end

  defp idle_timeout_ms do
    config = vast_ai_config()
    minutes = Keyword.get(config, :idle_timeout_minutes, 15)
    minutes * 60 * 1000
  end
end
