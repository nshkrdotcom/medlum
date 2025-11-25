defmodule Lumainus.Docling.VastAI.AutoShutdown do
  @moduledoc """
  Automatic shutdown of idle Vast.ai GPU instances.

  Runs on a configurable schedule (default: every 5 minutes) and destroys
  instances that have been idle for longer than the timeout (default: 15 minutes).

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

  # =============================================================================
  # Public API
  # =============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger an idle check and shutdown if needed.
  Can be called from crontab via Mix task or release command.

  Returns:
    - {:ok, :no_instances} - No instances running
    - {:ok, :still_active} - Instance running but not idle
    - {:ok, :destroyed, instance_id} - Instance was destroyed
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
      instances_destroyed: 0
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
      instances_destroyed: state.instances_destroyed,
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
        {:ok, :destroyed, _id} ->
          %{state | instances_destroyed: state.instances_destroyed + 1}

        _ ->
          state
      end

    {result, state}
  end

  defp perform_check do
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

    # Log the idle check to database
    GPU.log_auto_shutdown_check(instance_id, idle_minutes_value(idle_minutes), timeout)

    # Also update session idle time if we have one
    update_session_idle(instance_id, idle_minutes)

    case idle_minutes do
      :never ->
        # Never had activity - consider idle from start
        Logger.info(
          "[AutoShutdown] Instance #{instance_id} has never had activity, destroying..."
        )

        GPU.log(:auto_shutdown, :no_activity, "Instance has never had activity, will destroy",
          instance_id: instance_id,
          severity: "warning",
          source: "auto_shutdown"
        )

        destroy_instance(instance_id, "idle_timeout")

      mins when mins >= timeout ->
        Logger.info(
          "[AutoShutdown] Instance #{instance_id} idle for #{mins} min (>= #{timeout}), destroying..."
        )

        GPU.log_auto_shutdown_triggered(instance_id, mins)
        destroy_instance(instance_id, "idle_timeout")

      mins ->
        Logger.debug(
          "[AutoShutdown] Instance #{instance_id} idle for #{mins} min (< #{timeout}), keeping alive"
        )

        {:ok, :still_active}
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

  defp destroy_instance(instance_id, reason) do
    case VastAI.destroy(instance_id) do
      {:ok, _} ->
        Logger.info("[AutoShutdown] Instance #{instance_id} destroyed successfully")

        # Log destruction to database
        GPU.log(:auto_shutdown, :instance_destroyed, "Instance destroyed by auto-shutdown",
          instance_id: instance_id,
          severity: "warning",
          source: "auto_shutdown",
          details: %{reason: reason}
        )

        # Update session if exists
        case GPU.get_session_by_instance(instance_id) do
          nil -> :ok
          session -> GPU.destroy_session(session, reason)
        end

        {:ok, :destroyed, instance_id}

      {:error, reason} ->
        Logger.error(
          "[AutoShutdown] Failed to destroy instance #{instance_id}: #{inspect(reason)}"
        )

        GPU.log_error(:auto_shutdown, :destroy_failed, "Failed to destroy instance", reason,
          instance_id: instance_id,
          source: "auto_shutdown"
        )

        {:error, {:destroy_failed, reason}}
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
