defmodule Lumainus.AI.InvocationTelemetryHandler do
  @moduledoc """
  Telemetry handler for LLM invocation lifecycle events.

  Provides logging and debugging visibility for:
  - Invocation creation and linking
  - Status transitions (pending → running)
  - Orphaned invocation detection
  - Cleanup operations

  Call `attach/0` during application startup to enable.
  """

  require Logger

  @doc """
  Attach handlers to invocation lifecycle telemetry events.
  """
  def attach do
    events = [
      [:lumainus, :llm, :invocation, :created],
      [:lumainus, :llm, :invocation, :linked],
      [:lumainus, :llm, :invocation, :started],
      [:lumainus, :llm, :invocation, :orphaned],
      [:lumainus, :llm, :invocation, :cleaned]
    ]

    :telemetry.attach_many(
      "lumainus-invocation-lifecycle-handler",
      events,
      &handle_event/4,
      nil
    )
  end

  @doc """
  Detach handlers (useful for testing).
  """
  def detach do
    :telemetry.detach("lumainus-invocation-lifecycle-handler")
  end

  # --- Event Handlers ---

  def handle_event([:lumainus, :llm, :invocation, :created], _measurements, metadata, _config) do
    Logger.debug(
      "[Invocation] CREATED invocation_id=#{metadata.invocation_id} " <>
        "section_run_id=#{metadata.section_run_id} model=#{metadata.model}"
    )
  end

  def handle_event([:lumainus, :llm, :invocation, :linked], _measurements, metadata, _config) do
    Logger.debug(
      "[Invocation] LINKED invocation_id=#{metadata.invocation_id} " <>
        "section_run_id=#{metadata.section_run_id}"
    )
  end

  def handle_event([:lumainus, :llm, :invocation, :started], measurements, metadata, _config) do
    pending_ms = measurements[:pending_ms] || 0

    if pending_ms > 5_000 do
      Logger.warning(
        "[Invocation] STARTED (SLOW) invocation_id=#{metadata.invocation_id} " <>
          "model=#{metadata.model} pending_ms=#{pending_ms}"
      )
    else
      Logger.debug(
        "[Invocation] STARTED invocation_id=#{metadata.invocation_id} " <>
          "model=#{metadata.model} pending_ms=#{pending_ms}"
      )
    end
  end

  def handle_event([:lumainus, :llm, :invocation, :orphaned], measurements, metadata, _config) do
    age_minutes = measurements[:age_minutes] || 0
    reason = metadata[:reason] || :unknown

    # Always log orphaned as warning - this is critical for debugging
    Logger.warning(
      "[Invocation] ORPHANED invocation_id=#{metadata.invocation_id} " <>
        "model=#{metadata.model} age_minutes=#{age_minutes} reason=#{reason}"
    )

    # Emit metric for monitoring
    :telemetry.execute(
      [:lumainus, :llm, :invocation, :orphaned, :logged],
      %{count: 1, age_minutes: age_minutes},
      %{model: metadata.model, reason: reason}
    )
  end

  def handle_event([:lumainus, :llm, :invocation, :cleaned], _measurements, metadata, _config) do
    Logger.info(
      "[Invocation] CLEANED invocation_id=#{metadata.invocation_id} " <>
        "cleanup_type=#{metadata.cleanup_type}"
    )
  end

  # Catch-all for any new events
  def handle_event(event, measurements, metadata, _config) do
    Logger.debug(
      "[Invocation] Unknown event #{inspect(event)} " <>
        "measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
    )
  end
end
