defmodule Lumainus.Docling.VastAI.AutoShutdown do
  @moduledoc """
  Automatic shutdown of idle Vast.ai GPU instances.

  Runs on a configurable schedule (default: every 5 minutes) and STOPS
  instances that have been idle for longer than the timeout (default: 15 minutes).

  IMPORTANT: This module STOPS instances (preserving them for fast restart),
  it does NOT destroy them. Destroying is an admin-only operation.

  Stopped instances:
  - Can be restarted quickly (no Docker re-pull)
  - Cost ~$0 (only disk storage)
  - Preserve all configuration

  All events are logged to the database via the GPU context for audit trail.

  ## Configuration

      config :lumainus, :vast_ai_auto_shutdown,
        enabled: true,
        check_interval_minutes: 5,
        idle_timeout_minutes: 15

  ## Usage

      # Start the worker (automatically started by application supervisor)
      AutoShutdown.start_link()

      # Manually trigger a check (for crontab or testing)
      AutoShutdown.check_and_shutdown()

      # Get current status
      AutoShutdown.status()
  """

  use GenServer
  require Logger

  alias Lumainus.GPU
  alias Lumainus.VastAI
  alias Lumainus.VastAI.Instances
  alias Lumainus.Docling.VastAI.ActivityTracker
  alias Lumainus.Docling.VastAI.InstanceManager
  alias Lumainus.Docling.VastAI.ProvisioningState
  alias Lumainus.Docling.VastAI.StartTracker

  # =============================================================================
  # Public API
  # =============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger an idle check and stop if needed.
  Can be called from crontab via Mix task or release command.

  Returns:
    - {:ok, :no_instances} - No running instances found
    - {:ok, :still_active} - Instance running but not idle
    - {:ok, :stopped, instance_id} - Instance was stopped (can be restarted)
    - {:error, reason} - Error occurred
  """
  def check_and_shutdown do
    GenServer.call(__MODULE__, :check_and_shutdown, 30_000)
  end

  @doc """
  Get current auto-shutdown status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Check if auto-shutdown is enabled.
  """
  def enabled? do
    config(:enabled, true)
  end

  @doc """
  Get the check interval in minutes.
  """
  def check_interval_minutes do
    config(:check_interval_minutes, 5)
  end

  @doc """
  Get the idle timeout in minutes.
  """
  def idle_timeout_minutes do
    config(:idle_timeout_minutes, 15)
  end

  @doc """
  Immediately cleanup any duplicate running instances.

  Keeps only the most recently started instance and destroys all others.
  This can be called on-demand without waiting for the scheduled check.

  Returns:
    - {:ok, :no_duplicates} - Only one or zero instances running
    - {:ok, :cleaned, count} - Deleted `count` duplicate instances
    - {:error, reason} - Error occurred
  """
  def cleanup_duplicates do
    Logger.info("[AutoShutdown] Manual duplicate cleanup requested")

    case Instances.list() do
      {:ok, %{"instances" => instances}} when is_list(instances) ->
        running =
          Enum.filter(instances, fn inst ->
            inst["actual_status"] in ["running", "loading"] ||
              inst["cur_state"] in ["running", "loading"]
          end)

        case running do
          [] ->
            {:ok, :no_duplicates}

          [_single] ->
            {:ok, :no_duplicates}

          all_running ->
            # Sort by start_date descending (newest first) and keep only the newest
            sorted = Enum.sort_by(all_running, & &1["start_date"], :desc)
            [newest | extras] = sorted

            GPU.log(
              :auto_shutdown,
              :manual_duplicate_cleanup,
              "Manual duplicate cleanup initiated",
              severity: "warning",
              source: "auto_shutdown",
              details: %{keeping: newest["id"], deleting: Enum.map(extras, & &1["id"])}
            )

            # Delete all extras
            for extra <- extras do
              extra_id = extra["id"]
              Logger.warning("[AutoShutdown] Destroying duplicate instance #{extra_id}")
              VastAI.destroy(extra_id)
            end

            {:ok, :cleaned, length(extras)}
        end

      {:ok, _} ->
        {:ok, :no_duplicates}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def init(_opts) do
    state = %{
      last_check: nil,
      last_result: nil,
      checks_performed: 0,
      instances_stopped: 0
    }

    # Schedule first check
    if enabled?() do
      schedule_check()

      Logger.info(
        "[AutoShutdown] Started. Check every #{check_interval_minutes()} min, idle timeout #{idle_timeout_minutes()} min"
      )
    else
      Logger.info("[AutoShutdown] Disabled by config")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:check_and_shutdown, _from, state) do
    {result, state} = do_check_and_shutdown(state)
    {:reply, result, state}
  end

  def handle_call(:status, _from, state) do
    activity_status = ActivityTracker.status()

    status = %{
      enabled: enabled?(),
      check_interval_minutes: check_interval_minutes(),
      idle_timeout_minutes: idle_timeout_minutes(),
      last_check: state.last_check,
      last_result: state.last_result,
      checks_performed: state.checks_performed,
      instances_stopped: state.instances_stopped,
      activity: activity_status
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:scheduled_check, state) do
    {_result, state} = do_check_and_shutdown(state)

    # Schedule next check
    if enabled?() do
      schedule_check()
    end

    {:noreply, state}
  end

  # =============================================================================
  # Private
  # =============================================================================

  defp do_check_and_shutdown(state) do
    Logger.debug("[AutoShutdown] Running idle check...")

    result = perform_check()

    state = %{
      state
      | last_check: DateTime.utc_now(),
        last_result: result,
        checks_performed: state.checks_performed + 1
    }

    state =
      case result do
        {:ok, :stopped, _id} ->
          %{state | instances_stopped: state.instances_stopped + 1}

        _ ->
          state
      end

    {result, state}
  end

  defp perform_check do
    # CRITICAL: Skip check entirely if provisioning is in progress
    # We don't want to shut down instances while they're being set up
    if ProvisioningState.is_provisioning?() do
      Logger.info("[AutoShutdown] Skipping check - provisioning in progress")

      GPU.log(
        :auto_shutdown,
        :skipped_provisioning,
        "Auto-shutdown check skipped - provisioning in progress",
        severity: "info",
        source: "auto_shutdown"
      )

      {:ok, :provisioning_in_progress}
    else
      do_perform_check()
    end
  end

  defp do_perform_check do
    # Get running instances
    case Instances.list() do
      {:ok, %{"instances" => instances}} when is_list(instances) ->
        running =
          Enum.filter(instances, fn inst ->
            inst["actual_status"] in ["running", "loading"] ||
              inst["cur_state"] in ["running", "loading"]
          end)

        case running do
          [] ->
            Logger.debug("[AutoShutdown] No running instances")

            GPU.log(:auto_shutdown, :check_no_instances, "No running instances found",
              severity: "debug",
              source: "auto_shutdown"
            )

            {:ok, :no_instances}

          [instance] ->
            # Single instance - normal case
            check_instance_idle(instance)

          [_instance | _rest] = all_running ->
            # CRITICAL: Multiple instances running - delete extras immediately!
            Logger.warning(
              "[AutoShutdown] Found #{length(all_running)} running instances! Cleaning up duplicates..."
            )

            GPU.log(
              :auto_shutdown,
              :duplicate_instances_detected,
              "Multiple running instances detected - cleaning up",
              severity: "warning",
              source: "auto_shutdown",
              details: %{
                count: length(all_running),
                instance_ids: Enum.map(all_running, & &1["id"])
              }
            )

            # Sort by start_date descending (newest first) and keep only the newest
            sorted = Enum.sort_by(all_running, & &1["start_date"], :desc)
            [newest | extras] = sorted

            Logger.info(
              "[AutoShutdown] Keeping instance #{newest["id"]} (started: #{newest["start_date"]})"
            )

            # Delete all extras immediately
            for extra <- extras do
              extra_id = extra["id"]

              Logger.warning(
                "[AutoShutdown] Destroying duplicate instance #{extra_id} (started: #{extra["start_date"]})"
              )

              destroy_instance(extra_id, "duplicate_cleanup")
            end

            # Now check the remaining instance for idleness
            check_instance_idle(newest)
        end

      # Handle map format from API (single instance)
      {:ok, %{"instances" => %{"id" => _} = instance}} ->
        status = instance["actual_status"] || instance["cur_state"]

        if status in ["running", "loading"] do
          check_instance_idle(instance)
        else
          Logger.debug("[AutoShutdown] Instance not running (status: #{status})")
          {:ok, :no_instances}
        end

      {:ok, %{"instances" => _}} ->
        Logger.debug("[AutoShutdown] No running instances (empty or unexpected format)")
        {:ok, :no_instances}

      {:error, reason} ->
        Logger.error("[AutoShutdown] Failed to list instances: #{inspect(reason)}")

        GPU.log_error(
          :auto_shutdown,
          :list_failed,
          "Failed to list instances for idle check",
          reason,
          source: "auto_shutdown"
        )

        {:error, reason}
    end
  end

  defp check_instance_idle(instance) do
    instance_id = instance["id"]
    idle_minutes = ActivityTracker.idle_for_minutes()
    timeout = idle_timeout_minutes()

    # Calculate instance age from start_date
    instance_age_minutes = instance_age_in_minutes(instance)

    # Log the idle check to database
    GPU.log_auto_shutdown_check(instance_id, idle_minutes_value(idle_minutes), timeout)

    # Also update session idle time if we have one
    update_session_idle(instance_id, idle_minutes)

    case idle_minutes do
      :never ->
        # Never had activity - BUT check instance age first!
        # Don't stop newly provisioned instances - give them time to receive first request
        # Grace period = timeout (15 min by default)
        if instance_age_minutes < timeout do
          Logger.info(
            "[AutoShutdown] Instance #{instance_id} has no activity but is new (#{instance_age_minutes} min old < #{timeout} min grace period), keeping alive"
          )

          GPU.log(
            :auto_shutdown,
            :new_instance_grace,
            "New instance in grace period, keeping alive",
            instance_id: instance_id,
            severity: "info",
            source: "auto_shutdown",
            details: %{age_minutes: instance_age_minutes, grace_period: timeout}
          )

          {:ok, :still_active}
        else
          # Instance is old enough but never had activity - stop it
          Logger.info(
            "[AutoShutdown] Instance #{instance_id} has no activity and is #{instance_age_minutes} min old (>= #{timeout} min), stopping..."
          )

          GPU.log(
            :auto_shutdown,
            :no_activity,
            "Instance has never had activity and exceeded grace period, will stop",
            instance_id: instance_id,
            severity: "warning",
            source: "auto_shutdown",
            details: %{age_minutes: instance_age_minutes, grace_period: timeout}
          )

          stop_instance(instance_id, "idle_timeout")
        end

      mins when mins >= timeout ->
        # IMPORTANT: Check instance age too - if instance is new, the idle_minutes
        # might be stale from a previous instance. Don't shut down new instances.
        if instance_age_minutes < timeout do
          Logger.info(
            "[AutoShutdown] Instance #{instance_id} shows #{mins} min idle but is only #{instance_age_minutes} min old - keeping alive (stale activity data)"
          )

          GPU.log(
            :auto_shutdown,
            :stale_activity_ignored,
            "Instance shows idle but is new - ignoring stale activity data",
            instance_id: instance_id,
            severity: "info",
            source: "auto_shutdown",
            details: %{
              reported_idle_minutes: mins,
              instance_age_minutes: instance_age_minutes,
              timeout: timeout
            }
          )

          {:ok, :still_active}
        else
          Logger.info(
            "[AutoShutdown] Instance #{instance_id} idle for #{mins} min (>= #{timeout}), stopping..."
          )

          GPU.log_auto_shutdown_triggered(instance_id, mins)
          stop_instance(instance_id, "idle_timeout")
        end

      mins ->
        Logger.debug(
          "[AutoShutdown] Instance #{instance_id} idle for #{mins} min (< #{timeout}), keeping alive"
        )

        {:ok, :still_active}
    end
  end

  # Calculate how many minutes the instance has been running
  defp instance_age_in_minutes(instance) do
    api_age =
      case instance["start_date"] do
        start_date when is_number(start_date) ->
          # Vast.ai returns start_date as Unix timestamp (seconds)
          now = System.system_time(:second)
          max(0, div(now - trunc(start_date), 60))

        _ ->
          nil
      end

    local_age =
      case StartTracker.first_seen(instance["id"]) do
        nil ->
          nil

        first_seen_monotonic ->
          now = System.monotonic_time(:millisecond)
          max(0, div(now - first_seen_monotonic, 60_000))
      end

    cond do
      is_number(api_age) and is_number(local_age) -> min(api_age, local_age)
      is_number(api_age) -> api_age
      is_number(local_age) -> local_age
      true -> 0
    end
  end

  defp idle_minutes_value(:never), do: 9999
  defp idle_minutes_value(mins), do: mins

  defp update_session_idle(instance_id, idle_minutes) do
    case GPU.get_session_by_instance(instance_id) do
      nil ->
        :ok

      session ->
        mins =
          case idle_minutes do
            :never -> 0
            m -> m
          end

        GPU.update_session_idle(session, mins)
    end
  end

  defp stop_instance(instance_id, reason) do
    with {:ok, _} <- VastAI.stop(instance_id) do
      Logger.info("[AutoShutdown] Instance #{instance_id} stopped successfully")

      # Log stop to database
      GPU.log(:auto_shutdown, :instance_stopped, "Instance stopped by auto-shutdown",
        instance_id: instance_id,
        severity: "info",
        source: "auto_shutdown",
        details: %{reason: reason}
      )

      # Update session status to stopped (not destroyed - can be restarted)
      case GPU.get_session_by_instance(instance_id) do
        nil -> :ok
        session -> GPU.update_session_status(session, "stopped")
      end

      # Update InstanceManager to reflect stopped state
      InstanceManager.set_stopped(instance_id)

      {:ok, :stopped, instance_id}
    else
      {:error, err} ->
        Logger.error("[AutoShutdown] Failed to stop instance #{instance_id}: #{inspect(err)}")

        GPU.log_error(:auto_shutdown, :stop_failed, "Failed to stop instance", err,
          instance_id: instance_id,
          source: "auto_shutdown"
        )

        # Single retry after short backoff for transient API hiccups
        Process.sleep(2_000)

        case VastAI.stop(instance_id) do
          {:ok, _} ->
            Logger.info("[AutoShutdown] Retry stop succeeded for instance #{instance_id}")

            GPU.log(:auto_shutdown, :instance_stopped_retry, "Instance stopped on retry",
              instance_id: instance_id,
              severity: "info",
              source: "auto_shutdown",
              details: %{reason: reason}
            )

            case GPU.get_session_by_instance(instance_id) do
              nil -> :ok
              session -> GPU.update_session_status(session, "stopped")
            end

            InstanceManager.set_stopped(instance_id)
            {:ok, :stopped, instance_id}

          {:error, retry_err} ->
            GPU.log_error(
              :auto_shutdown,
              :stop_failed_retry,
              "Failed to stop instance (retry)",
              retry_err,
              instance_id: instance_id,
              source: "auto_shutdown"
            )

            {:error, {:stop_failed, retry_err}}
        end
    end
  end

  # Keep destroy_instance for duplicate cleanup (duplicates should be destroyed, not stopped)
  defp destroy_instance(instance_id, reason) do
    case VastAI.destroy(instance_id) do
      {:ok, _} ->
        Logger.info("[AutoShutdown] Duplicate instance #{instance_id} destroyed")

        GPU.log(:auto_shutdown, :instance_destroyed, "Duplicate instance destroyed",
          instance_id: instance_id,
          severity: "warning",
          source: "auto_shutdown",
          details: %{reason: reason}
        )

        # Destroy session for duplicates
        case GPU.get_session_by_instance(instance_id) do
          nil -> :ok
          session -> GPU.destroy_session(session, reason)
        end

        {:ok, :destroyed, instance_id}

      {:error, err} ->
        Logger.error(
          "[AutoShutdown] Failed to destroy duplicate instance #{instance_id}: #{inspect(err)}"
        )

        {:error, {:destroy_failed, err}}
    end
  end

  defp schedule_check do
    interval_ms = check_interval_minutes() * 60 * 1000
    Process.send_after(self(), :scheduled_check, interval_ms)
  end

  defp config(key, default) do
    Application.get_env(:lumainus, :vast_ai_auto_shutdown, [])
    |> Keyword.get(key, default)
  end
end
