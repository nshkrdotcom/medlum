defmodule Lumainus.Docling.VastAI.StartTracker do
  @moduledoc """
  Tracks when we first observed an instance locally, to provide
  a fallback age when Vast.ai start_date is missing or unreliable.

  All public functions are resilient - they gracefully handle the case
  where the ETS table doesn't exist yet (returns :ok or nil).
  """

  use GenServer

  @table :vast_ai_start_tracker

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record first-seen time (monotonic ms) for an instance if not already present.
  Returns :ok always (gracefully handles missing table).
  """
  def record_first_seen(instance_id) do
    ensure_table()

    try do
      :ets.insert_new(@table, {instance_id, System.monotonic_time(:millisecond)})
      :ok
    rescue
      ArgumentError -> :ok
    end
  end

  @doc """
  Get first-seen monotonic timestamp for an instance, or nil.
  Returns nil if table doesn't exist or instance not found.
  """
  def first_seen(instance_id) do
    try do
      case :ets.lookup(@table, instance_id) do
        [{^instance_id, ts}] -> ts
        _ -> nil
      end
    rescue
      ArgumentError -> nil
    end
  end

  @doc """
  Clear tracking for an instance (e.g., when destroyed).
  """
  def clear(instance_id) do
    try do
      :ets.delete(@table, instance_id)
      :ok
    rescue
      ArgumentError -> :ok
    end
  end

  @impl true
  def init(_opts) do
    # Create table if it doesn't already exist
    ensure_table()
    {:ok, %{}}
  end

  # Ensure the ETS table exists. Creates it if missing.
  # Safe to call multiple times.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
        rescue
          # Table was created between whereis and new (race condition) - that's fine
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end
end
