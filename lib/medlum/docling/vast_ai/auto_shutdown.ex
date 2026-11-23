defmodule Medlum.Docling.VastAI.AutoShutdown do
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

      config :medlum, :vast_ai_auto_shutdown,
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

  alias Medlum.Conversion.Job
  alias Medlum.GPU
  alias Medlum.Docling.VastAI.ActivityTracker
  alias Medlum.Docling.VastAI.InstanceManager
  alias Medlum.Docling.VastAI.ProvisioningState
  alias Medlum.Docling.VastAI.StartTracker
  alias Medlum.Repo

  import Ecto.Query

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
    - {:ok, :pending_shutdown, instance_id} - Idle threshold reached; shutdown pending
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
  Grace period after provisioning before idle shutdown logic applies.
  """
  def post_provisioning_grace_minutes do
    config(:post_provisioning_grace_minutes, 0)
  end

  @doc """
  Pending shutdown countdown (seconds). Activity during this window cancels shutdown.
  """
  def pending_shutdown_seconds do
    config(:pending_shutdown_seconds, 0)
  end

  @doc """
  Cancel any pending shutdown due to recent activity.
  """
  def touch_activity do
    GenServer.cast(__MODULE__, :activity_seen)
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

    case instances_module().list() do
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
              vast_ai_module().destroy(extra_id)
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
      instances_stopped: 0,
      pending_shutdown: nil
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
      post_provisioning_grace_minutes: post_provisioning_grace_minutes(),
      pending_shutdown_seconds: pending_shutdown_seconds(),
      last_check: state.last_check,
      last_result: state.last_result,
      checks_performed: state.checks_performed,
      instances_stopped: state.instances_stopped,
      activity: activity_status,
      pending_shutdown: format_pending_status(state.pending_shutdown)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:activity_seen, state) do
    new_state = cancel_pending_shutdown(state, :activity)
    {:noreply, new_state}
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

  def handle_info({:pending_shutdown_expire, instance_id, deadline_ms}, state) do
    case state.pending_shutdown do
      %{instance_id: ^instance_id, deadline_ms: ^deadline_ms} ->
        {result, new_state} = finalize_pending_shutdown(instance_id, state)

        new_state =
          new_state
          |> Map.put(:last_result, result)
          |> Map.put(:last_check, DateTime.utc_now())
          |> maybe_increment_stopped(result)

        {:noreply, new_state}

      _ ->
        Logger.debug(
          "[AutoShutdown] Ignoring stale pending shutdown timer for instance #{instance_id}"
        )

        {:noreply, state}
    end
  end

  # =============================================================================
  # Private
  # =============================================================================

  defp do_check_and_shutdown(state) do
    Logger.debug("[AutoShutdown] Running idle check...")

    {result, state} = perform_check(state)

    state = %{
      state
      | last_check: DateTime.utc_now(),
        last_result: result,
        checks_performed: state.checks_performed + 1
    }

    state = maybe_increment_stopped(state, result)

    {result, state}
  end

  defp perform_check(state) do
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

      state = cancel_pending_shutdown(state, :provisioning_in_progress)
      {{:ok, :provisioning_in_progress}, state}
    else
      do_perform_check(state)
    end
  end

  defp do_perform_check(state) do
    # Get running instances
    case instances_module().list() do
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

            state = cancel_pending_shutdown(state, :no_instances)
            {{:ok, :no_instances}, state}

          [instance] ->
            # Single instance - normal case
            check_instance_idle(instance, state)

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
            check_instance_idle(newest, state)
        end

      # Handle map format from API (single instance)
      {:ok, %{"instances" => %{"id" => _} = instance}} ->
        status = instance["actual_status"] || instance["cur_state"]

        if status in ["running", "loading"] do
          check_instance_idle(instance, state)
        else
          Logger.debug("[AutoShutdown] Instance not running (status: #{status})")
          state = cancel_pending_shutdown(state, :no_instances)
          {{:ok, :no_instances}, state}
        end

      {:ok, %{"instances" => _}} ->
        Logger.debug("[AutoShutdown] No running instances (empty or unexpected format)")
        state = cancel_pending_shutdown(state, :no_instances)
        {{:ok, :no_instances}, state}

      {:error, reason} ->
        Logger.error("[AutoShutdown] Failed to list instances: #{inspect(reason)}")

        GPU.log_error(
          :auto_shutdown,
          :list_failed,
          "Failed to list instances for idle check",
          reason,
          source: "auto_shutdown"
        )

        {{:error, reason}, state}
    end
  end

  defp check_instance_idle(instance, state) do
    instance = normalize_instance(instance)
    instance_id = instance["id"]
    state = cancel_pending_if_instance_changed(state, instance_id)
    idle_minutes = ActivityTracker.idle_for_minutes()
    timeout = idle_timeout_minutes()
    grace_minutes = post_provisioning_grace_minutes()
    instance_age_minutes = instance_age_in_minutes(instance)
    inflight_cloud_jobs? = cloud_jobs_inflight?()

    # Track first seen time for accurate grace calculation
    StartTracker.record_first_seen(instance_id)

    GPU.log_auto_shutdown_check(instance_id, idle_minutes_value(idle_minutes), timeout)
    update_session_idle(instance_id, idle_minutes)

    cond do
      inflight_cloud_jobs? ->
        new_state = cancel_pending_shutdown(state, :cloud_jobs_inflight)

        Logger.debug(
          "[AutoShutdown] Cloud conversions in flight; keeping instance #{instance_id} alive"
        )

        {{:ok, :still_active}, new_state}

      instance_age_minutes < grace_minutes ->
        new_state = cancel_pending_shutdown(state, :within_grace_period)

        Logger.debug(
          "[AutoShutdown] Instance #{instance_id} is #{instance_age_minutes} min old (< #{grace_minutes} min grace); skipping idle shutdown"
        )

        {{:ok, :still_active}, new_state}

      idle_minutes == :never and instance_age_minutes < max(timeout, grace_minutes) ->
        new_state = cancel_pending_shutdown(state, :never_seen_grace)

        Logger.info(
          "[AutoShutdown] Instance #{instance_id} has no activity but is only #{instance_age_minutes} min old; keeping alive until grace passes"
        )

        GPU.log(
          :auto_shutdown,
          :new_instance_grace,
          "New instance in grace period, keeping alive",
          instance_id: instance_id,
          severity: "info",
          source: "auto_shutdown",
          details: %{age_minutes: instance_age_minutes, grace_period: max(timeout, grace_minutes)}
        )

        {{:ok, :still_active}, new_state}

      idle_minutes == :never ->
        schedule_pending_shutdown(instance_id, idle_minutes, instance_age_minutes, state)

      idle_minutes < timeout ->
        new_state = cancel_pending_shutdown(state, :recent_activity)

        Logger.debug(
          "[AutoShutdown] Instance #{instance_id} idle for #{idle_minutes} min (< #{timeout}), keeping alive"
        )

        {{:ok, :still_active}, new_state}

      idle_minutes >= timeout and instance_age_minutes < timeout ->
        new_state = cancel_pending_shutdown(state, :stale_activity)

        Logger.info(
          "[AutoShutdown] Instance #{instance_id} shows #{idle_minutes} min idle but is #{instance_age_minutes} min old; treating idle as stale and keeping alive"
        )

        GPU.log(
          :auto_shutdown,
          :stale_activity_ignored,
          "Instance shows idle but is new - ignoring stale activity data",
          instance_id: instance_id,
          severity: "info",
          source: "auto_shutdown",
          details: %{
            reported_idle_minutes: idle_minutes,
            instance_age_minutes: instance_age_minutes,
            timeout: timeout
          }
        )

        {{:ok, :still_active}, new_state}

      idle_minutes >= timeout ->
        schedule_pending_shutdown(instance_id, idle_minutes, instance_age_minutes, state)
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

  defp schedule_pending_shutdown(instance_id, idle_minutes, instance_age_minutes, state) do
    window_ms = pending_window_ms()
    idle_label = format_idle_for_log(idle_minutes)

    if window_ms <= 0 do
      Logger.info(
        "[AutoShutdown] Instance #{instance_id} idle threshold reached; pending window is 0s, stopping immediately"
      )

      state = cancel_pending_shutdown(state, :no_pending_window)
      result = stop_instance(instance_id, "idle_timeout")
      {result, state}
    else
      state = cancel_pending_shutdown(state, :schedule_refresh)
      deadline_ms = System.monotonic_time(:millisecond) + window_ms

      timer_ref =
        Process.send_after(
          self(),
          {:pending_shutdown_expire, instance_id, deadline_ms},
          window_ms
        )

      seconds = div(window_ms, 1000)

      Logger.info(
        "[AutoShutdown] Instance #{instance_id} idle for #{idle_label}; scheduling shutdown in #{seconds}s (deadline #{deadline_ms})"
      )

      GPU.log(
        :auto_shutdown,
        :pending_shutdown_scheduled,
        "Idle threshold reached; shutdown pending",
        instance_id: instance_id,
        severity: "warning",
        source: "auto_shutdown",
        details: %{
          idle_minutes: idle_minutes_value(idle_minutes),
          idle_label: idle_label,
          instance_age_minutes: instance_age_minutes,
          pending_window_seconds: seconds
        }
      )

      new_state = %{
        state
        | pending_shutdown: %{
            instance_id: instance_id,
            deadline_ms: deadline_ms,
            timer_ref: timer_ref
          }
      }

      {{:ok, :pending_shutdown, instance_id}, new_state}
    end
  end

  defp pending_window_ms do
    max(0, pending_shutdown_seconds() * 1000)
  end

  defp cancel_pending_shutdown(state, reason) do
    case state.pending_shutdown do
      nil ->
        state

      %{timer_ref: timer_ref, instance_id: pending_instance} ->
        _ = Process.cancel_timer(timer_ref)
        log_pending_cancel(pending_instance, reason)
        %{state | pending_shutdown: nil}
    end
  end

  defp cancel_pending_if_instance_changed(state, instance_id) do
    case state.pending_shutdown do
      %{instance_id: pending_id} when pending_id != instance_id ->
        cancel_pending_shutdown(state, :instance_changed)

      _ ->
        state
    end
  end

  defp log_pending_cancel(instance_id, reason) do
    Logger.info(
      "[AutoShutdown] Pending shutdown for instance #{instance_id} cancelled (#{reason})"
    )
  end

  defp cloud_jobs_inflight? do
    active_states = [:queued, :provisioning, :starting, :processing]

    query =
      from(j in Job,
        where: j.backend_used == :cloud and j.state in ^active_states,
        select: j.id,
        limit: 1
      )

    Repo.exists?(query)
  rescue
    exception ->
      Logger.error(
        "[AutoShutdown] Failed to check cloud jobs in-flight: #{Exception.message(exception)}"
      )

      true
  end

  defp fetch_running_instance(instance_id) do
    case instances_module().get(instance_id) do
      {:ok, %{"instances" => inst}} ->
        fetch_running_instance_from_map(inst)

      {:ok, inst} ->
        fetch_running_instance_from_map(inst)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_running_instance_from_map(instance) do
    normalized = normalize_instance(instance)

    if instance_running?(normalized) do
      {:ok, normalized}
    else
      :not_running
    end
  end

  defp instance_running?(instance) do
    status = instance["actual_status"] || instance["cur_state"]
    status in ["running", "loading"]
  end

  defp normalize_instance(%{"instances" => inst}), do: inst
  defp normalize_instance(inst), do: inst

  defp format_pending_status(nil), do: nil

  defp format_pending_status(%{instance_id: id, deadline_ms: deadline_ms}) do
    now = System.monotonic_time(:millisecond)
    remaining_ms = max(deadline_ms - now, 0)

    %{
      instance_id: id,
      deadline_ms: deadline_ms,
      remaining_ms: remaining_ms,
      remaining_seconds: Float.round(remaining_ms / 1000, 1)
    }
  end

  defp format_idle_for_log(:never), do: "never (no activity recorded)"
  defp format_idle_for_log(mins), do: "#{mins} min"

  defp finalize_pending_shutdown(instance_id, state) do
    state = %{state | pending_shutdown: nil}

    cond do
      ProvisioningState.is_provisioning?() ->
        Logger.info(
          "[AutoShutdown] Pending shutdown cancelled for instance #{instance_id} - provisioning in progress"
        )

        {{:ok, :pending_cancelled_provisioning}, state}

      true ->
        case fetch_running_instance(instance_id) do
          {:ok, instance} ->
            idle_minutes = ActivityTracker.idle_for_minutes()
            timeout = idle_timeout_minutes()
            grace_minutes = post_provisioning_grace_minutes()
            instance_age_minutes = instance_age_in_minutes(instance)
            inflight_cloud_jobs? = cloud_jobs_inflight?()

            cond do
              inflight_cloud_jobs? ->
                Logger.info(
                  "[AutoShutdown] Pending shutdown cancelled for #{instance_id} - cloud conversions still active"
                )

                {{:ok, :pending_cancelled_jobs}, state}

              instance_age_minutes < grace_minutes ->
                Logger.info(
                  "[AutoShutdown] Pending shutdown cancelled for #{instance_id} - still within post-provisioning grace (#{instance_age_minutes} < #{grace_minutes} min)"
                )

                {{:ok, :pending_cancelled_grace}, state}

              idle_minutes == :never and instance_age_minutes < max(timeout, grace_minutes) ->
                Logger.info(
                  "[AutoShutdown] Pending shutdown cancelled for #{instance_id} - never active but grace not met (age #{instance_age_minutes} min)"
                )

                {{:ok, :pending_cancelled_grace}, state}

              is_integer(idle_minutes) and idle_minutes < timeout ->
                Logger.info(
                  "[AutoShutdown] Pending shutdown cancelled for #{instance_id} - activity detected (idle #{idle_minutes} < #{timeout})"
                )

                {{:ok, :pending_cancelled_activity}, state}

              is_integer(idle_minutes) and idle_minutes >= timeout and
                  instance_age_minutes < timeout ->
                Logger.info(
                  "[AutoShutdown] Pending shutdown cancelled for #{instance_id} - idle #{idle_minutes} but age #{instance_age_minutes} < #{timeout} (stale data)"
                )

                {{:ok, :pending_cancelled_stale}, state}

              true ->
                Logger.info(
                  "[AutoShutdown] Pending shutdown window expired; stopping instance #{instance_id} (idle #{format_idle_for_log(idle_minutes)})"
                )

                GPU.log_auto_shutdown_triggered(instance_id, idle_minutes_value(idle_minutes))
                {stop_instance(instance_id, "idle_timeout_pending_expired"), state}
            end

          :not_running ->
            Logger.info(
              "[AutoShutdown] Pending shutdown expired but instance #{instance_id} is no longer running; clearing pending state"
            )

            {{:ok, :pending_cancelled_no_instance}, state}

          {:error, reason} ->
            Logger.error(
              "[AutoShutdown] Failed to fetch instance #{instance_id} on pending shutdown expiry: #{inspect(reason)}"
            )

            GPU.log_error(
              :auto_shutdown,
              :pending_shutdown_fetch_failed,
              "Failed to fetch instance on pending shutdown expiry",
              reason,
              instance_id: instance_id,
              source: "auto_shutdown"
            )

            {{:error, {:pending_shutdown_fetch_failed, reason}}, state}
        end
    end
  end

  defp maybe_increment_stopped(state, result) do
    case result do
      {:ok, :stopped, _id} -> %{state | instances_stopped: state.instances_stopped + 1}
      _ -> state
    end
  end

  defp stop_instance(instance_id, reason) do
    with {:ok, _} <- vast_ai_module().stop(instance_id) do
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

        case vast_ai_module().stop(instance_id) do
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
    case vast_ai_module().destroy(instance_id) do
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
    Application.get_env(:medlum, :vast_ai_auto_shutdown, [])
    |> Keyword.get(key, default)
  end

  defp instances_module do
    config(:instances_module, Medlum.VastAI.Instances)
  end

  defp vast_ai_module do
    config(:vast_ai_module, Medlum.VastAI)
  end
end
