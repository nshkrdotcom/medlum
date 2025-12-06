defmodule Lumainus.AI.Telemetry do
  @moduledoc """
  Telemetry emission for LLM operations.

  ## Events

  ### [:lumainus, :llm, :request, :start]
  Emitted when an LLM request begins.

  Measurements: `%{system_time: integer()}`
  Metadata: `%{model: string(), use_case: atom(), mode: :streaming | :batch}`

  ### [:lumainus, :llm, :request, :stop]
  Emitted when an LLM request completes successfully.

  Measurements: `%{duration: integer(), input_tokens: integer(), output_tokens: integer()}`
  Metadata: `%{model: string(), use_case: atom(), mode: atom()}`

  ### [:lumainus, :llm, :request, :exception]
  Emitted when an LLM request fails.

  Measurements: `%{duration: integer()}`
  Metadata: `%{model: string(), use_case: atom(), error_type: atom(), error: term()}`

  ### [:lumainus, :llm, :rate_limit, :hit]
  Emitted when a request is rate limited.

  Measurements: `%{retry_after_ms: integer()}`
  Metadata: `%{model: string(), reason: atom(), source: atom()}`

  ### [:lumainus, :llm, :concurrency, :acquired]
  Emitted when a concurrency permit is acquired.

  Measurements: `%{wait_ms: integer()}`
  Metadata: `%{model: string(), current: integer(), max: integer()}`
  """

  require Logger

  @doc """
  Emit request start event.
  """
  def emit_start(model, use_case, mode) do
    :telemetry.execute(
      [:lumainus, :llm, :request, :start],
      %{system_time: System.system_time()},
      %{model: model, use_case: use_case, mode: mode}
    )
  end

  @doc """
  Emit request completion event.
  """
  def emit_stop(model, use_case, mode, start_time, usage \\ %{}) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:lumainus, :llm, :request, :stop],
      %{
        duration: duration,
        input_tokens: Map.get(usage, :input_tokens, 0),
        output_tokens: Map.get(usage, :output_tokens, 0),
        cached_tokens: Map.get(usage, :cached_tokens, 0)
      },
      %{model: model, use_case: use_case, mode: mode}
    )
  end

  @doc """
  Emit request exception event.
  """
  def emit_exception(model, use_case, start_time, error) do
    duration = System.monotonic_time() - start_time
    {error_type, _} = classify_error(error)

    :telemetry.execute(
      [:lumainus, :llm, :request, :exception],
      %{duration: duration},
      %{model: model, use_case: use_case, error_type: error_type, error: error}
    )
  end

  @doc """
  Emit rate limit hit event.
  """
  def emit_rate_limit_hit(model, reason, retry_after_ms, details \\ %{}) do
    :telemetry.execute(
      [:lumainus, :llm, :rate_limit, :hit],
      %{retry_after_ms: retry_after_ms || 0},
      Map.merge(%{model: model, reason: reason}, details)
    )
  end

  @doc """
  Emit rate limit wait event.
  """
  def emit_rate_limit_wait(model, wait_ms) do
    :telemetry.execute(
      [:lumainus, :llm, :rate_limit, :wait],
      %{wait_ms: wait_ms},
      %{model: model}
    )
  end

  @doc """
  Emit concurrency gate acquired event.
  """
  def emit_gate_acquired(model, wait_ms, current, max) do
    :telemetry.execute(
      [:lumainus, :llm, :concurrency, :acquired],
      %{wait_ms: wait_ms},
      %{model: model, current: current, max: max}
    )
  end

  @doc """
  Emit concurrency gate rejected event.
  """
  def emit_gate_rejected(model, reason) do
    :telemetry.execute(
      [:lumainus, :llm, :concurrency, :rejected],
      %{},
      %{model: model, reason: reason}
    )
  end

  defp classify_error({:rate_limited, _, _}), do: {:rate_limited, true}
  defp classify_error(%{type: :rate_limited}), do: {:rate_limited, true}
  defp classify_error(%{type: :api_error}), do: {:api_error, false}
  defp classify_error(%{type: :network_error}), do: {:network_error, true}
  defp classify_error({:error, {:rate_limited, _, _}}), do: {:rate_limited, true}
  defp classify_error(_), do: {:unknown, false}
end
