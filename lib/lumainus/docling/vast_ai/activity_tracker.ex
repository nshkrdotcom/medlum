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
