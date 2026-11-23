defmodule MedlumWeb.ReportsLive.GpuHandlers do
  @moduledoc """
  GPU and backend event handlers for ReportsLive.

  This module handles:
  - GPU instance management (start, stop, boot)
  - Backend switching (local vs cloud)
  - GPU status monitoring and health checks
  - Vast.ai synchronization
  """

  require Logger

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_navigate: 2, put_flash: 3]

  alias Ecto.Changeset
  alias Medlum.Accounts
  alias Medlum.Conversion.CloudStatus
  alias Medlum.Docling.VastAI.InstanceManager
  alias MedlumWeb.ReportsLive.GpuProvisioning

  # =============================================================================
  # Event Handlers - Backend Selection
  # =============================================================================

  @doc """
  Handles the "set_docling_backend" event to switch between local and cloud processing modes.
  """
  def handle_set_docling_backend(%{"backend" => backend}, socket) do
    # Only admins can change backend
    unless socket.assigns.can_manage_gpu? do
      {:noreply,
       put_flash(
         socket,
         :error,
         "You don't have permission to change processing mode."
       )}
    else
      backend_atom =
        backend
        |> String.downcase()
        |> normalize_backend_atom()

      cond do
        backend_atom == :cloud and not socket.assigns.fast_available? ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Cloud (GPU) is unavailable (admin-only provisioning). Switched to Standard."
           )
           |> assign(:docling_backend, :local)}

        true ->
          case Accounts.update_docling_backend(socket.assigns.current_scope.user, backend_atom) do
            {:ok, user} ->
              scope = %{socket.assigns.current_scope | user: user}

              {:noreply,
               socket
               |> assign(:docling_backend, backend_atom)
               |> assign(:current_scope, scope)
               |> maybe_fast_cost_flash(backend_atom)}

            {:error, changeset} ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 "Unable to save preference: #{humanize_errors(changeset)}"
               )}
          end
      end
    end
  rescue
    _ ->
      {:noreply, put_flash(socket, :error, "Unknown processing mode.")}
  end

  # =============================================================================
  # Event Handlers - GPU Instance Management
  # =============================================================================

  @doc """
  Handles the "boot_gpu_and_enable" event to provision and start a new GPU instance.
  """
  def handle_boot_gpu_and_enable(_params, socket) do
    # Only admins can boot GPU instances
    unless socket.assigns.can_manage_gpu? do
      {:noreply,
       put_flash(
         socket,
         :error,
         "You don't have permission to manage GPU instances."
       )}
    else
      # SAFETY CHECK: Prevent duplicate provisioning
      # Check if there's already an instance running before starting provisioning
      case InstanceManager.check_existing_instance() do
        {:ok, endpoint} when is_binary(endpoint) ->
          # Already have an endpoint tracked - just update user preference
          Logger.info(
            "[ReportsLive] GPU instance already exists at #{endpoint}, skipping provisioning"
          )

          socket =
            case Accounts.update_docling_backend(socket.assigns.current_scope.user, :cloud) do
              {:ok, user} ->
                scope = %{socket.assigns.current_scope | user: user}

                socket
                |> assign(:docling_backend, :cloud)
                |> assign(:current_scope, scope)

              {:error, _} ->
                socket
            end

          {:noreply,
           socket
           |> assign(:gpu_prompt_dismissed, true)
           |> put_flash(
             :info,
             "GPU instance already running! Cloud mode enabled."
           )
           |> push_navigate(to: "/admin/vast_ai")}

        {:ok, :running, instance_id} ->
          # Instance exists on Vast.ai but not tracked - log warning and redirect
          Logger.warning(
            "[ReportsLive] Found untracked running instance #{instance_id} on Vast.ai"
          )

          socket =
            case Accounts.update_docling_backend(socket.assigns.current_scope.user, :cloud) do
              {:ok, user} ->
                scope = %{socket.assigns.current_scope | user: user}

                socket
                |> assign(:docling_backend, :cloud)
                |> assign(:current_scope, scope)

              {:error, _} ->
                socket
            end

          {:noreply,
           socket
           |> assign(:gpu_prompt_dismissed, true)
           |> put_flash(
             :warning,
             "Found existing GPU instance ##{instance_id}. Check admin page for status."
           )
           |> push_navigate(to: "/admin/vast_ai")}

        {:ok, :none} ->
          # No instance exists - proceed with provisioning
          socket =
            case Accounts.update_docling_backend(socket.assigns.current_scope.user, :cloud) do
              {:ok, user} ->
                scope = %{socket.assigns.current_scope | user: user}

                socket
                |> assign(:docling_backend, :cloud)
                |> assign(:current_scope, scope)

              {:error, _} ->
                socket
            end

          # Start async provisioning in background (uses ProvisioningState for real-time logs)
          Task.start(fn -> GpuProvisioning.auto_provision_gpu() end)

          {:noreply,
           socket
           |> assign(:gpu_prompt_dismissed, true)
           |> put_flash(
             :info,
             "Starting GPU provisioning... Watch progress below."
           )
           |> push_navigate(to: "/admin/vast_ai")}

        {:error, reason} ->
          Logger.error("[ReportsLive] Failed to check existing instances: #{inspect(reason)}")

          {:noreply,
           put_flash(
             socket,
             :error,
             "Failed to check GPU status. Please try again."
           )}
      end
    end
  end

  @doc """
  Handles the "dismiss_gpu_prompt" event to hide the GPU prompt banner.
  """
  def handle_dismiss_gpu_prompt(_params, socket) do
    {:noreply, assign(socket, :gpu_prompt_dismissed, true)}
  end

  @doc """
  Handles the "start_gpu" event to start a stopped GPU instance.
  """
  def handle_start_gpu(_params, socket) do
    unless socket.assigns.can_manage_gpu? do
      {:noreply,
       put_flash(
         socket,
         :error,
         "You don't have permission to manage GPU instances."
       )}
    else
      case InstanceManager.start_instance() do
        {:ok, endpoint} ->
          Logger.info("[ReportsLive] GPU instance started, endpoint: #{endpoint}")

          # Update user preference to cloud
          socket =
            case Accounts.update_docling_backend(socket.assigns.current_scope.user, :cloud) do
              {:ok, user} ->
                scope = %{socket.assigns.current_scope | user: user}

                socket
                |> assign(:docling_backend, :cloud)
                |> assign(:current_scope, scope)

              {:error, _} ->
                socket
            end

          {:noreply,
           socket
           |> assign(:gpu_instance_status, %{
             status: :running,
             endpoint: endpoint,
             instance_id: socket.assigns.gpu_instance_status[:instance_id]
           })
           |> assign(:fast_available?, nil)
           |> assign(:fast_unavailable_reason, "Checking...")
           |> put_flash(
             :info,
             "GPU instance starting... This may take a moment."
           )}

        {:error, :no_instance} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "No GPU instance exists. Contact admin to provision one."
           )}

        {:error, :instance_loading} ->
          {:noreply, put_flash(socket, :info, "GPU instance is already starting...")}

        {:error, reason} ->
          Logger.error("[ReportsLive] Failed to start GPU: #{inspect(reason)}")

          {:noreply, put_flash(socket, :error, "Failed to start GPU: #{inspect(reason)}")}
      end
    end
  end

  @doc """
  Handles the "stop_gpu" event to stop a running GPU instance.
  """
  def handle_stop_gpu(_params, socket) do
    unless socket.assigns.can_manage_gpu? do
      {:noreply,
       put_flash(
         socket,
         :error,
         "You don't have permission to manage GPU instances."
       )}
    else
      case InstanceManager.stop_instance() do
        :ok ->
          Logger.info("[ReportsLive] GPU instance stopped")

          {:noreply,
           socket
           |> assign(:gpu_instance_status, %{
             status: :stopped,
             endpoint: nil,
             instance_id: socket.assigns.gpu_instance_status[:instance_id]
           })
           |> assign(:fast_available?, false)
           |> assign(:fast_unavailable_reason, "GPU instance stopped")
           |> put_flash(
             :info,
             "GPU instance stopped. Start it again when needed."
           )}

        {:error, :no_instance} ->
          {:noreply, put_flash(socket, :info, "No GPU instance to stop.")}

        {:error, reason} ->
          Logger.error("[ReportsLive] Failed to stop GPU: #{inspect(reason)}")

          {:noreply, put_flash(socket, :error, "Failed to stop GPU: #{inspect(reason)}")}
      end
    end
  end

  # =============================================================================
  # Info Handlers - GPU Status Updates
  # =============================================================================

  @doc """
  Handles the {:gpu_status_changed, status_map} message when GPU instance status changes.
  """
  def handle_gpu_status_changed(status_map, socket) do
    Logger.debug(
      "[ReportsLive] GPU status changed: status=#{status_map.status} healthy=#{status_map.healthy}"
    )

    # Derive fast_available? from the new status
    {fast_available?, fast_reason} =
      case status_map do
        %{status: :running, healthy: false, health_check_error: error} ->
          {false, error || "GPU service unhealthy"}

        %{status: :running, healthy: healthy} when healthy != false ->
          {true, nil}

        %{status: :loading} ->
          {false, "GPU instance still loading"}

        %{status: :stopped} ->
          {false, "GPU instance stopped"}

        _ ->
          {false, "No GPU instance"}
      end

    # Normalize status for UI
    normalized_status =
      case status_map.status do
        :running -> :running
        :stopped -> :stopped
        :loading -> :loading
        :none -> :no_instance
        _ -> :unknown
      end

    gpu_instance_status = %{
      status: normalized_status,
      endpoint: status_map.endpoint,
      instance_id: status_map.instance_id,
      healthy: status_map.healthy,
      health_check_error: status_map.health_check_error
    }

    {:noreply,
     socket
     |> assign(:gpu_instance_status, gpu_instance_status)
     |> assign(:fast_available?, fast_available?)
     |> assign(:fast_unavailable_reason, format_backend_reason(fast_reason))}
  end

  @doc """
  Handles the :check_fast_backend_health message (DEPRECATED - kept for backwards compatibility).
  """
  def handle_check_fast_backend_health(socket) do
    # No-op - health checks are now handled by InstanceManager
    Logger.debug("[ReportsLive] Ignoring legacy :check_fast_backend_health message")
    {:noreply, socket}
  end

  @doc """
  Handles the {:fast_backend_health_result, {available?, reason}} message.
  """
  def handle_fast_backend_health_result({available?, reason}, socket) do
    # When health check fails but we know an instance exists, show better status
    # This handles the case where instance was just provisioned but service is still booting
    #
    # IMPORTANT: Check InstanceManager directly for current state, not socket assigns
    # which may be stale from page load
    current_instance_status = check_gpu_instance_status_fast()

    Logger.info(
      "[ReportsLive] Health result received: available?=#{inspect(available?)}, " <>
        "instance_status=#{inspect(current_instance_status.status)}"
    )

    {final_available?, final_reason, should_retry?} =
      case {available?, current_instance_status} do
        {true, _} ->
          # Health check passed - all good
          Logger.info("[ReportsLive] Setting fast_available?=true")
          {true, nil, false}

        {false, %{status: :running, endpoint: endpoint}}
        when is_binary(endpoint) and endpoint != "" ->
          # Instance exists but health check failed - service is probably still starting
          # (Caddy installing, SSL certs, etc.)
          Logger.info(
            "[ReportsLive] Health check failed but instance exists at #{endpoint} - service starting"
          )

          {false, "Service starting (GPU instance running, waiting for service to be ready)...",
           true}

        {false, %{status: :loading}} ->
          # Instance still loading
          {false, "GPU instance still loading...", true}

        {false, _} ->
          # No instance or truly unavailable
          {false, reason, false}
      end

    # Also update the gpu_instance_status assign to match current reality
    socket = assign(socket, :gpu_instance_status, current_instance_status)

    socket =
      socket
      |> assign(:fast_available?, final_available?)
      |> assign(:fast_reason, final_reason)
      |> assign(:fast_unavailable_reason, format_backend_reason(final_reason))

    # Auto-retry health check if instance exists but service not ready yet
    # Retry every 10 seconds up to a reasonable limit
    retry_count = Map.get(socket.assigns, :health_check_retry_count, 0)
    # 3 minutes of retrying (18 * 10 seconds)
    max_retries = 18

    socket =
      cond do
        # Health check passed - reset retry count
        final_available? == true ->
          if retry_count > 0 do
            Logger.info("[ReportsLive] Health check succeeded after #{retry_count} retries")
          end

          assign(socket, :health_check_retry_count, 0)

        # Should retry and haven't exhausted retries
        should_retry? and retry_count < max_retries ->
          Logger.debug(
            "[ReportsLive] Scheduling health check retry #{retry_count + 1}/#{max_retries} in 10s"
          )

          Process.send_after(self(), :check_fast_backend_health, 10_000)
          assign(socket, :health_check_retry_count, retry_count + 1)

        # Exhausted retries
        retry_count >= max_retries ->
          Logger.warning(
            "[ReportsLive] Health check retries exhausted after #{max_retries} attempts"
          )

          socket

        # Not retrying
        true ->
          socket
      end

    # If health check failed with connection error, trigger a sync
    # This handles cases where the instance was deleted externally
    # But only if we don't have a known instance (to avoid syncing when just booting)
    if final_available? == false and is_binary(reason) and
         (String.contains?(reason, "timeout") or String.contains?(reason, "econnrefused") or
            String.contains?(reason, "nxdomain") or String.contains?(reason, "transport_error")) do
      # Only sync if we don't think an instance exists (use fresh status, not stale assigns)
      if current_instance_status.status not in [:running, :loading] do
        Logger.info(
          "[ReportsLive] Health check failed with connection error, triggering Vast.ai sync"
        )

        send(self(), :trigger_vast_ai_sync)
      end
    end

    {:noreply, socket}
  end

  @doc """
  Handles the :trigger_vast_ai_sync message to synchronize with Vast.ai.
  """
  def handle_trigger_vast_ai_sync(socket) do
    # Run sync in background to not block
    lv_pid = self()

    Task.start(fn ->
      result = InstanceManager.sync_with_vast_ai()
      send(lv_pid, {:vast_ai_sync_result, result})
    end)

    {:noreply, socket}
  end

  @doc """
  Handles the {:vast_ai_sync_result, result} message after Vast.ai sync completes.
  """
  def handle_vast_ai_sync_result(result, socket) do
    case result do
      {:ok, :synced, endpoint} ->
        Logger.info("[ReportsLive] Sync found and adopted instance at #{endpoint}")
        # Update status and trigger fresh health check
        socket =
          socket
          |> assign(:gpu_instance_status, %{
            status: :running,
            endpoint: endpoint
          })
          |> assign(:fast_available?, nil)
          |> assign(:fast_reason, "Checking...")
          |> assign(:fast_unavailable_reason, "Checking...")
          |> assign(:health_check_retry_count, 0)
          |> put_flash(:info, "Found running GPU instance at #{endpoint}")

        # Trigger fresh health check
        send(self(), :check_fast_backend_health)
        {:noreply, socket}

      {:ok, :cleared} ->
        Logger.info("[ReportsLive] Sync cleared stale instance state")
        # Update all related assigns
        {:noreply,
         socket
         |> assign(:gpu_instance_status, %{status: :no_instance, endpoint: nil})
         |> assign(:fast_available?, false)
         |> assign(:fast_reason, "No GPU instance")
         |> assign(:fast_unavailable_reason, "No GPU instance")}

      {:ok, :no_change} ->
        Logger.debug("[ReportsLive] Sync completed with no changes")
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("[ReportsLive] Sync failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  @doc """
  Checks GPU instance status by querying CloudStatus.
  """
  def check_gpu_instance_status_fast do
    cloud_status = CloudStatus.get()

    # Convert CloudStatus to legacy format for backward compatibility with UI
    case cloud_status do
      %{availability: :ready, endpoint: endpoint, instance_info: info} ->
        %{
          status: :running,
          endpoint: endpoint,
          instance_id: get_in(info || %{}, [:instance_id]),
          healthy: true,
          health_check_error: nil,
          cloud_status: cloud_status
        }

      %{availability: :provisioning, endpoint: endpoint, instance_info: info} ->
        # Could be loading or running-but-unhealthy
        instance_status = get_in(info || %{}, [:status])

        %{
          status: if(instance_status == :running, do: :running, else: :loading),
          endpoint: endpoint,
          instance_id: get_in(info || %{}, [:instance_id]),
          healthy: false,
          health_check_error: "Starting up...",
          cloud_status: cloud_status
        }

      %{availability: :unavailable, message: _message} ->
        %{
          status: :unavailable,
          endpoint: nil,
          instance_id: nil,
          healthy: false,
          health_check_error: cloud_status[:detail],
          cloud_status: cloud_status
        }

      _ ->
        %{
          status: :unknown,
          endpoint: nil,
          instance_id: nil,
          healthy: nil,
          health_check_error: "CloudStatus unavailable",
          cloud_status: cloud_status
        }
    end
  end

  @doc """
  Shows a flash message when switching to cloud backend about potential costs.
  """
  def maybe_fast_cost_flash(socket, :cloud) do
    put_flash(socket, :info, "Cloud (GPU) uses remote GPUs and may incur cost.")
  end

  def maybe_fast_cost_flash(socket, _), do: socket

  @doc """
  Formats backend unavailability reasons for user-friendly display.
  """
  def format_backend_reason(nil), do: ""

  def format_backend_reason(reason) when is_binary(reason) do
    # Return user-friendly messages for common reasons
    cond do
      String.contains?(reason, "Service starting") ->
        # Already user-friendly
        reason

      String.contains?(reason, "GPU instance still loading") ->
        reason

      String.contains?(reason, "No GPU instance") ->
        reason

      String.contains?(reason, "not configured") ->
        reason

      String.contains?(reason, "timeout") ->
        "connection timed out"

      String.contains?(reason, "econnrefused") ->
        "service not responding"

      String.contains?(reason, "nxdomain") ->
        "hostname not found"

      String.contains?(reason, "transport_error") ->
        "network error"

      true ->
        # Truncate long technical messages
        if String.length(reason) > 50 do
          String.slice(reason, 0, 47) <> "..."
        else
          reason
        end
    end
  end

  def format_backend_reason(reason), do: inspect(reason)

  # =============================================================================
  # Private Helper Functions
  # =============================================================================

  defp normalize_backend_atom(nil), do: :local
  defp normalize_backend_atom(:local), do: :local
  defp normalize_backend_atom("local"), do: :local
  defp normalize_backend_atom(:cloud), do: :cloud
  defp normalize_backend_atom("cloud"), do: :cloud
  defp normalize_backend_atom(:fast), do: :cloud
  defp normalize_backend_atom("fast"), do: :cloud
  defp normalize_backend_atom(_), do: :local

  defp humanize_errors(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} ->
      "#{humanize_field(field)} #{List.first(messages)}"
    end)
    |> Enum.join(", ")
  end

  defp humanize_field(field) do
    field
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
