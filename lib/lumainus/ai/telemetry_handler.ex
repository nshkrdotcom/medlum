defmodule Lumainus.AI.TelemetryHandler do
  @moduledoc """
  Attaches to gemini_ex telemetry events and re-emits as lumainus events.

  Call `attach/0` during application startup to enable.
  """

  require Logger

  @doc """
  Attach handlers to gemini_ex telemetry events.
  """
  def attach do
    events = [
      [:gemini, :rate_limit, :request, :start],
      [:gemini, :rate_limit, :request, :stop],
      [:gemini, :rate_limit, :wait],
      [:gemini, :rate_limit, :error],
      [:gemini, :rate_limit, :budget, :reserved],
      [:gemini, :rate_limit, :budget, :rejected]
    ]

    :telemetry.attach_many(
      "lumainus-gemini-handler",
      events,
      &handle_event/4,
      nil
    )
  end

  @doc """
  Detach handlers (useful for testing).
  """
  def detach do
    :telemetry.detach("lumainus-gemini-handler")
  end

  def handle_event([:gemini, :rate_limit, :wait], measurements, metadata, _config) do
    Logger.debug(
      "Gemini rate limit wait: model=#{metadata[:model]} wait_ms=#{measurements[:wait_ms]}"
    )

    :telemetry.execute(
      [:lumainus, :llm, :rate_limit, :wait],
      %{wait_ms: measurements[:wait_ms] || 0},
      %{model: metadata[:model], source: :gemini_ex}
    )
  end

  def handle_event([:gemini, :rate_limit, :error], _measurements, metadata, _config) do
    Logger.warning(
      "Gemini rate limit error: model=#{metadata[:model]} reason=#{metadata[:reason]}"
    )

    :telemetry.execute(
      [:lumainus, :llm, :rate_limit, :hit],
      %{retry_after_ms: 0},
      %{
        model: metadata[:model],
        reason: metadata[:reason],
        source: :gemini_ex
      }
    )
  end

  def handle_event([:gemini, :rate_limit, :budget, :rejected], _measurements, metadata, _config) do
    Logger.warning("Gemini budget rejected: model=#{metadata[:model]}")

    :telemetry.execute(
      [:lumainus, :llm, :rate_limit, :hit],
      %{retry_after_ms: 0},
      %{
        model: metadata[:model],
        reason: :over_budget,
        source: :gemini_ex
      }
    )
  end

  def handle_event([:gemini, :rate_limit, :budget, :reserved], _measurements, metadata, _config) do
    Logger.debug(
      "Gemini budget reserved: model=#{metadata[:model]} tokens=#{metadata[:reserved_tokens]}"
    )

    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config) do
    :ok
  end
end
