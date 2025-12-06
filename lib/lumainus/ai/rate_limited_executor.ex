defmodule Lumainus.AI.RateLimitedExecutor do
  @moduledoc """
  Application-level rate limiting wrapper for LLM calls.

  Provides a consistent gate regardless of streaming vs batch mode.
  Works in conjunction with gemini_ex rate limiter as defense in depth.

  ## Usage

      RateLimitedExecutor.execute(:report_section, :streaming, fn ->
        AI.client().stream_generate(...)
      end)
  """

  alias Lumainus.AI.{ConcurrencyGate, Telemetry, Models}

  require Logger

  @doc """
  Execute an LLM operation with rate limiting and telemetry.

  ## Parameters

  - `use_case` - The use case atom (e.g., `:report_section`)
  - `mode` - `:streaming` or `:batch`
  - `fun` - Zero-arity function that performs the LLM call
  - `opts` - Options:
    - `:timeout` - Gate acquisition timeout (default: 60_000)
    - `:skip_gate` - Skip the concurrency gate (default: false)

  ## Returns

  The result of `fun.()`, or `{:error, {:gate_rejected, reason}}` if
  the concurrency gate rejects the request.
  """
  def execute(use_case, mode, fun, opts \\ []) do
    model = Models.resolve(use_case)
    start_time = System.monotonic_time()

    Telemetry.emit_start(model, use_case, mode)

    result =
      if Keyword.get(opts, :skip_gate, false) do
        execute_with_telemetry(fun, model, use_case, mode, start_time)
      else
        execute_with_gate(fun, model, use_case, mode, start_time, opts)
      end

    result
  end

  @doc """
  Check if the gate is available for a new request.
  """
  def available? do
    ConcurrencyGate.available?()
  end

  @doc """
  Get current gate status.
  """
  def status do
    ConcurrencyGate.status()
  end

  defp execute_with_gate(fun, model, use_case, mode, start_time, opts) do
    gate_start = System.monotonic_time()

    case ConcurrencyGate.acquire(opts) do
      :ok ->
        wait_ms =
          System.convert_time_unit(System.monotonic_time() - gate_start, :native, :millisecond)

        status = ConcurrencyGate.status()
        Telemetry.emit_gate_acquired(model, wait_ms, status.current, status.max)

        try do
          execute_with_telemetry(fun, model, use_case, mode, start_time)
        after
          ConcurrencyGate.release()
        end

      {:queued, position} ->
        Logger.debug("LLM request queued at position #{position} for #{use_case}")

        receive do
          {:permit_granted, _ref} ->
            wait_ms =
              System.convert_time_unit(
                System.monotonic_time() - gate_start,
                :native,
                :millisecond
              )

            status = ConcurrencyGate.status()
            Telemetry.emit_gate_acquired(model, wait_ms, status.current, status.max)

            try do
              execute_with_telemetry(fun, model, use_case, mode, start_time)
            after
              ConcurrencyGate.release()
            end
        after
          Keyword.get(opts, :timeout, 60_000) ->
            Telemetry.emit_gate_rejected(model, :timeout)
            {:error, {:gate_rejected, :timeout}}
        end

      {:rejected, reason} ->
        Logger.warning("LLM request rejected by gate: #{reason}")
        Telemetry.emit_gate_rejected(model, reason)
        Telemetry.emit_exception(model, use_case, start_time, {:gate_rejected, reason})
        {:error, {:gate_rejected, reason}}
    end
  end

  defp execute_with_telemetry(fun, model, use_case, mode, start_time) do
    case fun.() do
      {:ok, result} = success ->
        usage = extract_usage(result)
        Telemetry.emit_stop(model, use_case, mode, start_time, usage)
        success

      {:error, {:rate_limited, retry_after, details}} = error ->
        Telemetry.emit_rate_limit_hit(model, :rate_limited, retry_after_ms(retry_after), details)
        Telemetry.emit_exception(model, use_case, start_time, error)
        error

      {:error, _reason} = error ->
        Telemetry.emit_exception(model, use_case, start_time, error)
        error

      other ->
        # Streaming returns stream_id, not {:ok, result}
        Telemetry.emit_stop(model, use_case, mode, start_time, %{})
        other
    end
  end

  defp extract_usage(result) when is_map(result) do
    cond do
      Map.has_key?(result, :usage_metadata) ->
        um = result.usage_metadata

        %{
          input_tokens: Map.get(um, :prompt_token_count, 0),
          output_tokens: Map.get(um, :candidates_token_count, 0),
          cached_tokens: Map.get(um, :cached_content_token_count, 0)
        }

      Map.has_key?(result, "usageMetadata") ->
        um = result["usageMetadata"]

        %{
          input_tokens: Map.get(um, "promptTokenCount", 0),
          output_tokens: Map.get(um, "candidatesTokenCount", 0),
          cached_tokens: Map.get(um, "cachedContentTokenCount", 0)
        }

      true ->
        %{}
    end
  end

  defp extract_usage(_), do: %{}

  defp retry_after_ms(nil), do: 0

  defp retry_after_ms(%DateTime{} = dt),
    do: max(0, DateTime.diff(dt, DateTime.utc_now(), :millisecond))

  defp retry_after_ms(ms) when is_integer(ms), do: ms
  defp retry_after_ms(_), do: 0
end
