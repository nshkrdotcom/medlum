defmodule Lumainus.Docling.VastAI.ActivityTracker do
  @moduledoc """
  Tracks Docling activity to determine when GPU instances are idle.

  Uses ETS for fast access. Activity is recorded whenever:
  - A document is processed via cloud backend
  - Health check is performed
  - Manual activity update is triggered

  ## Usage

      # Record activity
      ActivityTracker.record_activity()

      # Check if idle
      ActivityTracker.idle_for_minutes() >= 15

      # Get last activity time
      ActivityTracker.last_activity()
  """

  use GenServer
  require Logger

  alias Lumainus.Docling.VastAI.AutoShutdown

  @table_name :vast_ai_activity
  @activity_key :last_activity

  # =============================================================================
  # Public API
  # =============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record that activity happened now.
  Called whenever Docling cloud backend is used.
  """
  def record_activity do
    :ets.insert(@table_name, {@activity_key, System.monotonic_time(:millisecond)})
    AutoShutdown.touch_activity()
    :ok
  end

  @doc """
  Reset activity tracking. Call this when a new instance is provisioned
  to clear stale timestamps from previous instances.
  """
  def reset do
    :ets.delete(@table_name, @activity_key)
    Logger.info("[ActivityTracker] Reset - cleared previous activity timestamp")
    :ok
  end

  @doc """
  Record activity if none exists yet. Useful to seed activity on instance start.
  """
  def record_activity_if_missing do
    case last_activity() do
      nil -> record_activity()
      _ -> :ok
    end
  end

  @doc """
  Get the last activity timestamp (monotonic milliseconds).
  Returns nil if no activity recorded.
  """
  def last_activity do
    case :ets.lookup(@table_name, @activity_key) do
      [{@activity_key, timestamp}] -> timestamp
      [] -> nil
    end
  end

  @doc """
  Get minutes since last activity.
  Returns :never if no activity recorded.
  """
  def idle_for_minutes do
    case last_activity() do
      nil ->
        :never

      timestamp ->
        now = System.monotonic_time(:millisecond)
        div(now - timestamp, 60_000)
    end
  end

  @doc """
  Check if the system has been idle for at least `minutes` minutes.
  """
  def idle_for?(minutes) when is_integer(minutes) do
    case idle_for_minutes() do
      :never -> true
      idle_mins -> idle_mins >= minutes
    end
  end

  @doc """
  Get activity status as a map (useful for debugging/display).
  """
  def status do
    idle = idle_for_minutes()

    %{
      last_activity: last_activity(),
      idle_minutes: idle,
      idle_formatted:
        case idle do
          :never -> "never active"
          mins -> "#{mins} minutes"
        end
    }
  end

  @doc """
  Calculate idle time in milliseconds from a given timestamp or state.

  Accepts:
  - An integer timestamp (monotonic milliseconds)
  - A map with `:last_activity` field
  - `nil` (returns 0)

  ## Examples

      iex> calculate_idle_time(System.monotonic_time(:millisecond) - 60_000)
      60000

      iex> calculate_idle_time(%{last_activity: timestamp})
      # Returns ms since timestamp

      iex> calculate_idle_time(nil)
      0
  """
  def calculate_idle_time(timestamp) when is_integer(timestamp) do
    now = System.monotonic_time(:millisecond)
    now - timestamp
  end

  def calculate_idle_time(%{last_activity: timestamp}) when is_integer(timestamp) do
    calculate_idle_time(timestamp)
  end

  def calculate_idle_time(%{last_activity: nil}), do: 0
  def calculate_idle_time(nil), do: 0

  @doc """
  Schedule an idle check message to be sent after the given interval.

  Sends `:check_idle` message to the calling process after `interval_ms` milliseconds.
  """
  def schedule_idle_check(interval_ms \\ 60_000) do
    Process.send_after(self(), :check_idle, interval_ms)
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def init(_opts) do
    # Create ETS table for fast access
    :ets.new(@table_name, [:named_table, :public, :set])

    Logger.info("[ActivityTracker] Started")
    {:ok, %{}}
  end
end
