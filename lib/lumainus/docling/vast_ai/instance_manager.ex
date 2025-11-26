defmodule Lumainus.Docling.VastAI.InstanceManager do
  @moduledoc """
  Manages Vast.ai GPU instance lifecycle with start/stop support.

  Tracks instance state:
  - :none - No instance exists
  - :running - Instance is running and available
  - :stopped - Instance exists but is stopped (can be started quickly)
  - :loading - Instance is starting up

  ## Architecture

  - **Admin** provisions and destroys instances (via mix tasks or admin UI)
  - **Users** can only start/stop existing instances (via /reports UI)
  - **AutoShutdown** stops (not destroys) idle instances to preserve state

  ## Configuration

      config :lumainus, :docling,
        vast_ai: [
          api_key: "...",
          gpu_name: "RTX_3090",
          min_disk_gb: 20,
          idle_timeout_minutes: 15
        ]

  ## Usage

      # Check instance status
      status = InstanceManager.status()  # %{status: :running, instance_id: 123, endpoint: "..."}

      # Start a stopped instance
      {:ok, endpoint} = InstanceManager.start_instance()

      # Stop a running instance
      :ok = InstanceManager.stop_instance()

      # Update activity (resets idle timer)
      :ok = InstanceManager.update_activity()

      # Admin only: destroy instance completely
      :ok = InstanceManager.destroy_instance()
  """

  use GenServer
  require Logger

  alias Lumainus.GPU
  alias Lumainus.VastAI
  alias Lumainus.VastAI.RemoteDiagnostics
  alias Lumainus.Cloudflare
  alias Lumainus.Cloudflare.Tunnel
  alias Lumainus.Docling.VastAI.StartTracker
  alias Lumainus.Docling.VastAI.ActivityTracker
  @compile {:no_warn_undefined, Lumainus.VastAI}

  @idle_check_interval_ms 60_000

  # Instance status values
  @status_none :none
  @status_running :running
  @status_stopped :stopped
  @status_loading :loading

  # =============================================================================
  # Public API
  # =============================================================================

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Get comprehensive status of the current instance.

  Returns a map with:
  - :status - One of :none, :running, :stopped, :loading
  - :instance_id - The Vast.ai instance ID (or nil)
  - :endpoint - The service endpoint URL (or nil)
  - :last_activity - Timestamp of last activity (or nil)
  """
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  Start a stopped instance.

  Only works if an instance exists and is in stopped state.
  Returns {:ok, endpoint} on success, {:error, reason} on failure.
  """
  def start_instance(server \\ __MODULE__) do
    GenServer.call(server, :start_instance, 60_000)
  end

  @doc """
  Stop a running instance.

  Stops the instance but preserves it for fast restart.
  Returns :ok on success, {:error, reason} on failure.
  """
  def stop_instance(server \\ __MODULE__) do
    GenServer.call(server, :stop_instance, 30_000)
  end

  @doc """
  Mark instance as stopped (called by AutoShutdown).

  This updates the local state to reflect that the instance was stopped.
  """
  def set_stopped(instance_id, server \\ __MODULE__) do
    GenServer.cast(server, {:set_stopped, instance_id})
  end

  @doc """
  Ensure an instance is running and return its endpoint.

  If instance is stopped, starts it. If no instance exists, returns error
  (provisioning is admin-only now).
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
  Get current Cloudflare Tunnel ID.
  """
  def current_tunnel_id(server \\ __MODULE__) do
    GenServer.call(server, :current_tunnel_id)
  end

  @doc """
  Destroy current instance (ADMIN ONLY).

  Permanently destroys the instance. Use stop_instance for normal shutdown.
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
  Set the instance endpoint from external provisioning (e.g., admin provision).

  This is called when provisioning happens through a different code path
  to ensure InstanceManager knows about the instance.

  If `ip` is provided, DNS will be automatically updated to point to that IP.
  If `ip` is nil, we will try to extract the IP from `endpoint` for DNS updates.

  ## Options
    - `:tunnel_id` - Cloudflare Tunnel ID (for cleanup on destroy)
  """
  def set_endpoint(instance_id, endpoint) do
    set_endpoint(instance_id, endpoint, nil, [])
  end

  @doc """
  Set the instance endpoint with IP for DNS update.
  """
  def set_endpoint(instance_id, endpoint, ip) when is_binary(ip) or is_nil(ip) do
    set_endpoint(instance_id, endpoint, ip, [])
  end

  def set_endpoint(instance_id, endpoint, server) when is_atom(server) or is_pid(server) do
    set_endpoint(instance_id, endpoint, nil, [], server)
  end

  def set_endpoint(instance_id, endpoint, ip, opts) when is_list(opts) do
    set_endpoint(instance_id, endpoint, ip, opts, __MODULE__)
  end

  def set_endpoint(instance_id, endpoint, ip, server) when is_atom(server) or is_pid(server) do
    set_endpoint(instance_id, endpoint, ip, [], server)
  end

  def set_endpoint(instance_id, endpoint, ip, opts, server) do
    tunnel_id = Keyword.get(opts, :tunnel_id)
    # DNS updates can be slow; allow generous timeout
    GenServer.call(server, {:set_endpoint, instance_id, endpoint, ip, tunnel_id}, 30_000)
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
       # Cloudflare Tunnel ID for cleanup
       tunnel_id: nil,
       status: @status_none,
       last_activity: nil,
       provisioning: false
     }}
  end

  # Handle :status - return comprehensive status
  @impl true
  def handle_call(:status, _from, state) do
    status_map = %{
      status: state.status,
      instance_id: state.instance_id,
      endpoint: state.endpoint,
      tunnel_id: state.tunnel_id,
      last_activity: state.last_activity
    }

    {:reply, status_map, state}
  end

  # Handle :start_instance - start a stopped instance
  def handle_call(:start_instance, _from, %{status: @status_stopped, instance_id: id} = state)
      when not is_nil(id) do
    Logger.info("[InstanceManager] Starting stopped instance #{id}...")

    case VastAI.start(id) do
      {:ok, _} ->
        Logger.info("[InstanceManager] Instance #{id} start command sent")

        GPU.log(:lifecycle, :instance_starting, "Starting stopped instance",
          instance_id: id,
          source: "instance_manager"
        )

        # Wait for instance to be ready
        case wait_for_instance_running(id) do
          {:ok, endpoint, ip} ->
            # Update DNS to point to the started instance
            update_dns_for_instance(ip, id)

            # Start services inside container (onstart only runs on first provision)
            ensure_services_after_start(id, ip)

            # Mark activity and first-seen for graceful idle handling
            ActivityTracker.record_activity_if_missing()
            StartTracker.record_first_seen(id)

            state = %{
              state
              | status: @status_running,
                endpoint: endpoint,
                last_activity: System.monotonic_time(:millisecond)
            }

            # Update session status
            case GPU.get_session_by_instance(id) do
              nil -> :ok
              session -> GPU.update_session_status(session, "running")
            end

            schedule_idle_check()
            {:reply, {:ok, endpoint}, state}

          {:error, reason} ->
            {:reply, {:error, {:start_failed, reason}}, state}
        end

      {:error, reason} ->
        Logger.error("[InstanceManager] Failed to start instance #{id}: #{inspect(reason)}")
        {:reply, {:error, {:start_failed, reason}}, state}
    end
  end

  def handle_call(:start_instance, _from, %{status: @status_running, endpoint: endpoint} = state) do
    # Already running
    {:reply, {:ok, endpoint}, state}
  end

  def handle_call(:start_instance, _from, %{status: @status_none} = state) do
    {:reply, {:error, :no_instance}, state}
  end

  def handle_call(:start_instance, _from, %{status: @status_loading} = state) do
    {:reply, {:error, :instance_loading}, state}
  end

  # Handle :stop_instance - stop a running instance (preserves it)
  def handle_call(:stop_instance, _from, %{status: @status_running, instance_id: id} = state)
      when not is_nil(id) do
    Logger.info("[InstanceManager] Stopping instance #{id}...")

    case VastAI.stop(id) do
      {:ok, _} ->
        Logger.info("[InstanceManager] Instance #{id} stopped successfully")

        GPU.log(:lifecycle, :instance_stopped, "Instance stopped by user",
          instance_id: id,
          source: "instance_manager"
        )

        # Update session status
        case GPU.get_session_by_instance(id) do
          nil -> :ok
          session -> GPU.update_session_status(session, "stopped")
        end

        state = %{state | status: @status_stopped, endpoint: nil}
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error("[InstanceManager] Failed to stop instance #{id}: #{inspect(reason)}")
        {:reply, {:error, {:stop_failed, reason}}, state}
    end
  end

  def handle_call(:stop_instance, _from, %{status: @status_stopped} = state) do
    # Already stopped
    {:reply, :ok, state}
  end

  def handle_call(:stop_instance, _from, %{status: @status_none} = state) do
    {:reply, {:error, :no_instance}, state}
  end

  # Handle :ensure_instance - now just starts stopped instances, doesn't provision
  def handle_call(:ensure_instance, _from, %{status: @status_running, endpoint: endpoint} = state) do
    state = %{state | last_activity: System.monotonic_time(:millisecond)}
    {:reply, {:ok, endpoint}, state}
  end

  def handle_call(:ensure_instance, _from, %{status: @status_stopped} = state) do
    # Instance exists but stopped - try to start it
    handle_call(:start_instance, nil, state)
  end

  def handle_call(:ensure_instance, _from, %{status: @status_none} = state) do
    # No instance - sync with Vast.ai first to see if there's one we don't know about
    case check_vast_ai_for_instances() do
      {:ok, :running, instance_id, ip} when is_binary(ip) and ip != "" ->
        # Found running instance - check if we should recover or cleanup
        case maybe_recover_or_cleanup_orphan(instance_id, ip) do
          {:ok, endpoint} ->
            # Seed activity/start time on recovery
            ActivityTracker.record_activity_if_missing()
            StartTracker.record_first_seen(instance_id)

            GPU.log(:lifecycle, :instance_recovered, "Recovered existing Vast.ai instance",
              instance_id: instance_id,
              endpoint: endpoint,
              source: "instance_manager"
            )

            state = %{
              state
              | instance_id: instance_id,
                endpoint: endpoint,
                status: @status_running,
                last_activity: System.monotonic_time(:millisecond)
            }

            schedule_idle_check()
            {:reply, {:ok, endpoint}, state}

          {:error, :orphan_destroyed} ->
            # Instance was orphaned (no cloudflared), destroyed it
            {:reply, {:error, :no_instance_provision_required}, state}
        end

      {:ok, :stopped, instance_id} ->
        # Found stopped instance - update state and try to start
        Logger.info("[InstanceManager] Found stopped instance #{instance_id}, starting...")
        state = %{state | instance_id: instance_id, status: @status_stopped}
        handle_call(:start_instance, nil, state)

      {:ok, :loading, instance_id} ->
        Logger.warning("[InstanceManager] Instance #{instance_id} is still loading")
        {:reply, {:error, {:instance_loading, instance_id}}, state}

      {:ok, :none} ->
        # No instance exists - provisioning is admin-only
        Logger.info("[InstanceManager] No instance exists. Provisioning is admin-only.")
        {:reply, {:error, :no_instance_provision_required}, state}

      {:error, reason} ->
        Logger.error("[InstanceManager] Failed to check Vast.ai: #{inspect(reason)}")
        {:reply, {:error, {:api_check_failed, reason}}, state}
    end
  end

  def handle_call(:ensure_instance, _from, %{status: @status_loading} = state) do
    {:reply, {:error, :instance_loading}, state}
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

  def handle_call(:current_tunnel_id, _from, state) do
    {:reply, state.tunnel_id, state}
  end

  def handle_call(:destroy_instance, _from, state) do
    if state.instance_id do
      GPU.log(:lifecycle, :destroy_requested, "Instance destruction requested (ADMIN)",
        instance_id: state.instance_id,
        tunnel_id: state.tunnel_id,
        source: "instance_manager"
      )

      destroy_vast_instance(state.instance_id, "admin_manual")

      # Clean up Cloudflare Tunnel if present
      if state.tunnel_id do
        Logger.info("[InstanceManager] Cleaning up Cloudflare Tunnel #{state.tunnel_id}")

        case Tunnel.cleanup_for_vast_ai(state.tunnel_id) do
          :ok ->
            Logger.info("[InstanceManager] Tunnel #{state.tunnel_id} cleaned up")

          {:error, reason} ->
            Logger.warning("[InstanceManager] Failed to cleanup tunnel: #{inspect(reason)}")
        end
      end
    end

    {:reply, :ok,
     %{
       state
       | instance_id: nil,
         endpoint: nil,
         tunnel_id: nil,
         status: @status_none,
         last_activity: nil
     }}
  end

  def handle_call({:set_endpoint, instance_id, endpoint, ip, tunnel_id}, _from, state) do
    Logger.info(
      "[InstanceManager] Setting endpoint from external provisioning: #{instance_id} -> #{endpoint}" <>
        if(tunnel_id, do: " (tunnel: #{tunnel_id})", else: "")
    )

    # Record first-seen time for grace calculation
    StartTracker.record_first_seen(instance_id)

    # Update DNS when we know the IP (either provided or extracted from endpoint)
    # Note: With Cloudflare Tunnel, DNS is a CNAME to the tunnel, not A record to IP
    ip_for_dns = ip || extract_ip_from_endpoint(endpoint)

    if ip_for_dns && is_nil(tunnel_id) do
      # Only update A record if not using tunnel (tunnel uses CNAME)
      update_dns_for_instance(ip_for_dns, instance_id)
    end

    GPU.log(:lifecycle, :endpoint_set, "Instance endpoint set from external provisioning",
      instance_id: instance_id,
      endpoint: endpoint,
      tunnel_id: tunnel_id,
      source: "instance_manager"
    )

    state = %{
      state
      | instance_id: instance_id,
        endpoint: endpoint,
        tunnel_id: tunnel_id,
        status: @status_running,
        last_activity: System.monotonic_time(:millisecond)
    }

    schedule_idle_check()
    {:reply, :ok, state}
  end

  # Backward compatibility: handle old 4-arg version without tunnel_id
  def handle_call({:set_endpoint, instance_id, endpoint, ip}, from, state) do
    handle_call({:set_endpoint, instance_id, endpoint, ip, nil}, from, state)
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
        tunnel_id: state.tunnel_id,
        source: "instance_manager"
      )
    end

    {:reply, :ok,
     %{
       state
       | instance_id: nil,
         endpoint: nil,
         tunnel_id: nil,
         status: @status_none,
         last_activity: nil
     }}
  end

  @impl true
  def handle_cast(:update_activity, state) do
    {:noreply, %{state | last_activity: System.monotonic_time(:millisecond)}}
  end

  # Handle set_stopped from AutoShutdown
  def handle_cast({:set_stopped, instance_id}, state) do
    if state.instance_id == instance_id do
      Logger.info("[InstanceManager] Instance #{instance_id} marked as stopped by AutoShutdown")
      {:noreply, %{state | status: @status_stopped, endpoint: nil}}
    else
      # Instance ID doesn't match - may be stale notification
      Logger.warning(
        "[InstanceManager] Received set_stopped for #{instance_id} but tracking #{state.instance_id}"
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:check_idle, state) do
    # NOTE: This is InstanceManager's own idle check. AutoShutdown handles the main idle logic.
    # This is a backup in case AutoShutdown isn't running.
    # We STOP (not destroy) to preserve the instance.
    now = System.monotonic_time(:millisecond)
    idle_time = now - (state.last_activity || now)
    idle_timeout = idle_timeout_ms()
    idle_minutes = div(idle_time, 60_000)
    timeout_minutes = div(idle_timeout, 60_000)

    if idle_time > idle_timeout and state.instance_id and state.status == @status_running do
      Logger.info(
        "[InstanceManager] Stopping idle instance #{state.instance_id} (idle for #{idle_minutes} minutes)"
      )

      # Log to database
      GPU.log(:lifecycle, :idle_stop, "Instance idle timeout - stopping (preserving instance)",
        instance_id: state.instance_id,
        severity: "warning",
        source: "instance_manager",
        details: %{
          idle_minutes: idle_minutes,
          timeout_minutes: timeout_minutes
        }
      )

      # STOP instead of destroy
      case VastAI.stop(state.instance_id) do
        {:ok, _} ->
          # Update session status
          case GPU.get_session_by_instance(state.instance_id) do
            nil -> :ok
            session -> GPU.update_session_status(session, "stopped")
          end

          {:noreply, %{state | status: @status_stopped, endpoint: nil}}

        {:error, reason} ->
          Logger.error("[InstanceManager] Failed to stop idle instance: #{inspect(reason)}")
          schedule_idle_check()
          {:noreply, state}
      end
    else
      schedule_idle_check()
      {:noreply, state}
    end
  end

  def handle_info(:startup_sync, state) do
    Logger.info("[InstanceManager] Running startup sync with Vast.ai...")

    case check_vast_ai_for_instances() do
      {:ok, :none} ->
        Logger.info("[InstanceManager] No instances found on Vast.ai")
        {:noreply, %{state | status: @status_none}}

      {:ok, :running, instance_id, ip} when is_binary(ip) and ip != "" ->
        # Check if we should recover or cleanup orphan
        case maybe_recover_or_cleanup_orphan(instance_id, ip) do
          {:ok, endpoint} ->
            # Seed activity/start time on recovery
            ActivityTracker.record_activity_if_missing()
            StartTracker.record_first_seen(instance_id)

            Logger.info(
              "[InstanceManager] Found running instance #{instance_id} at #{endpoint} on startup"
            )

            GPU.log(:lifecycle, :startup_sync, "Recovered running instance on startup",
              instance_id: instance_id,
              endpoint: endpoint,
              source: "instance_manager"
            )

            new_state = %{
              state
              | instance_id: instance_id,
                endpoint: endpoint,
                status: @status_running,
                last_activity: System.monotonic_time(:millisecond)
            }

            schedule_idle_check()
            {:noreply, new_state}

          {:error, :orphan_destroyed} ->
            Logger.info("[InstanceManager] Orphaned instance destroyed on startup")
            {:noreply, %{state | status: @status_none}}
        end

      {:ok, :stopped, instance_id} ->
        Logger.info("[InstanceManager] Found stopped instance #{instance_id} on startup")

        GPU.log(:lifecycle, :startup_sync, "Found stopped instance on startup",
          instance_id: instance_id,
          source: "instance_manager"
        )

        new_state = %{state | instance_id: instance_id, status: @status_stopped}
        {:noreply, new_state}

      {:ok, :loading, instance_id} ->
        Logger.info("[InstanceManager] Found loading instance #{instance_id} on startup")
        new_state = %{state | instance_id: instance_id, status: @status_loading}
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("[InstanceManager] Startup sync failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  # Self-healing: decide whether to recover an instance or destroy it as orphaned
  # Orphaned instances are those without cloudflared when we're using tunnel-based setup
  defp maybe_recover_or_cleanup_orphan(instance_id, ip) do
    alias Lumainus.VastAI.Instances

    # Check if there's an active tunnel for our domain
    case Tunnel.find_by_name("docling-vast") do
      {:ok, [_tunnel | _]} ->
        # Tunnel exists - this is a tunnel-based setup
        # Instance without tunnel_id is orphaned (doesn't have cloudflared)
        Logger.warning(
          "[InstanceManager] Found orphaned instance #{instance_id} (tunnel exists but instance not tunnel-enabled)"
        )

        Logger.info("[InstanceManager] Destroying orphaned instance #{instance_id}...")

        case Instances.destroy(instance_id) do
          {:ok, _} ->
            Logger.info("[InstanceManager] Destroyed orphaned instance #{instance_id}")

            GPU.log(
              :lifecycle,
              :orphan_destroyed,
              "Destroyed orphaned instance (not tunnel-enabled)",
              instance_id: instance_id,
              ip: ip,
              source: "instance_manager"
            )

          {:error, reason} ->
            Logger.warning("[InstanceManager] Failed to destroy orphan: #{inspect(reason)}")
        end

        {:error, :orphan_destroyed}

      {:ok, []} ->
        # No tunnel - use legacy A record recovery
        Logger.info(
          "[InstanceManager] Recovering instance #{instance_id} at #{ip} (no tunnel, using A record)"
        )

        update_dns_for_instance(ip, instance_id)
        endpoint = recover_endpoint(ip)
        {:ok, endpoint}

      {:error, reason} ->
        # Can't check tunnels - fall back to legacy recovery
        Logger.warning(
          "[InstanceManager] Could not check tunnels: #{inspect(reason)}, using legacy recovery"
        )

        update_dns_for_instance(ip, instance_id)
        endpoint = recover_endpoint(ip)
        {:ok, endpoint}
    end
  end

  defp extract_ip_from_endpoint(endpoint) when is_binary(endpoint) do
    case Regex.run(~r/(\d{1,3}(?:\.\d{1,3}){3})/, endpoint) do
      [_, ip] ->
        case :inet.parse_address(String.to_charlist(ip)) do
          {:ok, _tuple} -> ip
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_ip_from_endpoint(_), do: nil

  # Update Cloudflare DNS to point to the instance IP
  defp update_dns_for_instance(ip, instance_id) when is_binary(ip) and ip != "" do
    Logger.info("[InstanceManager] Updating DNS for instance #{instance_id} to IP #{ip}")

    case Cloudflare.update_dns_record(ip) do
      {:ok, %{fqdn: fqdn}} ->
        Logger.info("[InstanceManager] DNS updated: #{fqdn} → #{ip}")

        GPU.log(:lifecycle, :dns_updated, "DNS updated for instance",
          instance_id: instance_id,
          ip: ip,
          fqdn: fqdn,
          source: "instance_manager"
        )

        :ok

      {:error, reason} ->
        Logger.error("[InstanceManager] Failed to update DNS: #{inspect(reason)}")

        GPU.log_error(:lifecycle, :dns_update_failed, "Failed to update DNS", reason,
          instance_id: instance_id,
          ip: ip,
          source: "instance_manager"
        )

        {:error, reason}
    end
  end

  defp update_dns_for_instance(ip, _instance_id) do
    Logger.warning("[InstanceManager] Cannot update DNS - invalid IP: #{inspect(ip)}")
    {:error, :invalid_ip}
  end

  # Ensure services are running after instance start/restart
  # The onstart script only runs on first provision, not on restart
  defp ensure_services_after_start(instance_id, ip) do
    Logger.info("[InstanceManager] Ensuring services running on instance #{instance_id}...")

    # Get SSH port from Vast.ai
    case VastAI.status(instance_id) do
      {:ok, %{"ssh_port" => ssh_port}} when is_integer(ssh_port) ->
        opts = [
          ip: ip,
          ssh_port: ssh_port,
          instance_id: instance_id,
          port: 8044,
          domain: Cloudflare.cloud_fqdn()
        ]

        case RemoteDiagnostics.ensure_services_running(opts) do
          {:ok, result} ->
            Logger.info(
              "[InstanceManager] Services status: uvicorn=#{result.uvicorn}, cloudflared=#{result.cloudflared}, healthy=#{result.healthy}"
            )

            GPU.log(:lifecycle, :services_started, "Services started on instance",
              instance_id: instance_id,
              uvicorn: result.uvicorn,
              cloudflared: result.cloudflared,
              healthy: result.healthy,
              source: "instance_manager"
            )

            :ok

          {:error, reason} ->
            Logger.error("[InstanceManager] Failed to ensure services: #{inspect(reason)}")

            GPU.log_error(:lifecycle, :services_start_failed, "Failed to start services", reason,
              instance_id: instance_id,
              source: "instance_manager"
            )

            {:error, reason}
        end

      {:ok, instance_data} ->
        Logger.warning(
          "[InstanceManager] No SSH port in instance data: #{inspect(instance_data)}"
        )

        {:error, :no_ssh_port}

      {:error, reason} ->
        Logger.error("[InstanceManager] Failed to get instance status: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp schedule_idle_check do
    Process.send_after(self(), :check_idle, @idle_check_interval_ms)
  end

  # Check Vast.ai for any instances (running, stopped, or loading)
  # Returns:
  #   {:ok, :none} - No instances
  #   {:ok, :running, instance_id, ip} - Running instance with IP
  #   {:ok, :stopped, instance_id} - Stopped instance
  #   {:ok, :loading, instance_id} - Loading instance (no IP yet)
  #   {:error, reason} - API error
  defp check_vast_ai_for_instances do
    alias Lumainus.VastAI.Instances

    case Instances.list() do
      {:ok, %{"instances" => instances}} when is_list(instances) ->
        # Filter to find our instances (could be multiple)
        case instances do
          [] ->
            {:ok, :none}

          _ ->
            # Find first instance that's not destroyed
            instance =
              Enum.find(instances, fn inst ->
                status = inst["actual_status"] || inst["cur_state"]
                status not in ["exited", "destroyed", nil]
              end)

            classify_instance(instance)
        end

      {:ok, %{"instances" => %{"id" => _} = instance}} ->
        # Single instance returned as map
        classify_instance(instance)

      {:ok, _} ->
        {:ok, :none}

      {:error, reason} ->
        Logger.error("[InstanceManager] Failed to check Vast.ai instances: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp classify_instance(nil), do: {:ok, :none}

  defp classify_instance(instance) do
    instance_id = instance["id"]
    status = instance["actual_status"] || instance["cur_state"]
    ip = instance["public_ipaddr"]

    cond do
      status == "running" and is_binary(ip) and ip != "" ->
        {:ok, :running, instance_id, ip}

      status == "running" ->
        # Running but no IP yet
        {:ok, :loading, instance_id}

      status == "loading" ->
        {:ok, :loading, instance_id}

      status == "stopped" ->
        {:ok, :stopped, instance_id}

      status in ["exited", "destroyed"] ->
        {:ok, :none}

      true ->
        # Unknown status - treat as loading
        Logger.warning("[InstanceManager] Unknown instance status: #{status}")
        {:ok, :loading, instance_id}
    end
  end

  # Wait for instance to become running after start command
  # Returns {:ok, endpoint, ip} on success
  defp wait_for_instance_running(instance_id, timeout_ms \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_interval = 5_000

    do_wait_for_running(instance_id, deadline, poll_interval)
  end

  defp do_wait_for_running(instance_id, deadline, poll_interval) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      case VastAI.status(instance_id) do
        {:ok, %{"actual_status" => "running", "public_ipaddr" => ip}}
        when is_binary(ip) and ip != "" ->
          endpoint = recover_endpoint(ip)
          {:ok, endpoint, ip}

        {:ok, %{"actual_status" => "running"}} ->
          # Running but no IP yet - keep waiting
          Process.sleep(poll_interval)
          do_wait_for_running(instance_id, deadline, poll_interval)

        {:ok, %{"actual_status" => status}} when status in ["loading", "starting", "stopped"] ->
          Process.sleep(poll_interval)
          do_wait_for_running(instance_id, deadline, poll_interval)

        {:ok, %{"actual_status" => "exited"}} ->
          {:error, :instance_exited}

        {:error, reason} ->
          {:error, reason}

        _ ->
          Process.sleep(poll_interval)
          do_wait_for_running(instance_id, deadline, poll_interval)
      end
    end
  end

  # Keep the old function for backward compatibility (used by sync_with_vast_ai)
  defp check_vast_ai_for_running_instances do
    case check_vast_ai_for_instances() do
      {:ok, :running, instance_id, ip} -> {:ok, instance_id, ip}
      {:ok, :loading, instance_id} -> {:ok, instance_id, nil}
      {:ok, :stopped, _instance_id} -> {:ok, :none}
      {:ok, :none} -> {:ok, :none}
      {:error, reason} -> {:error, reason}
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

  # NOTE: Provisioning is now done via mix tasks (mix vast_ai.provision)
  # The provision_instance and provision_via_api functions have been removed.

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

  defp destroy_via_api(instance_id, _config) do
    Logger.info("[VastAI] Destroying instance #{instance_id}")
    VastAI.destroy(instance_id)
    :ok
  end

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
