defmodule Medlum.Conversion.Infrastructure.Resilience.RetryPolicy do
  @moduledoc """
  Domain-aware retry helper backed by the `retry` library.

  ## CRITICAL: Only for Idempotent Operations

  This policy should ONLY wrap:
  - Health checks
  - Status polling
  - SSE reconnection attempts

  NEVER wrap:
  - `enqueue/2` (creates duplicate jobs)
  - `convert/2` (processes file twice)

  ## Configuration

  - `:max_attempts` — Total attempts including first try (default: 3)
  - `:base_delay_ms` — Initial delay between retries (default: 1000)
  - `:max_delay_ms` — Maximum delay cap (default: 30_000)
  - `:jitter_percent` — Random jitter percentage (default: 20)
  - `:on_retry` — Callback on each retry attempt
  - `:sleep` — Sleep function (useful for tests), defaults to `&Process.sleep/1`
  """

  import Retry.DelayStreams

  alias Medlum.Conversion.Infrastructure.Telemetry.Emitter

  @default_max_attempts 3
  @default_base_delay_ms 1_000
  @default_max_delay_ms 30_000
  @default_jitter_percent 20

  @type opts :: [
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          jitter_percent: non_neg_integer(),
          on_retry: (attempt :: pos_integer(), delay :: pos_integer(), error :: term() -> any()),
          sleep: (non_neg_integer() -> any())
        ]

  @doc """
  Execute a function with exponential backoff using the `retry` delay streams.

  Returns the function's result when it succeeds or when retries are exhausted.
  """
  @spec with_retry((-> result), opts()) :: result when result: term()
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    max_attempts = opts |> Keyword.get(:max_attempts, @default_max_attempts) |> max(1)
    sleep_fn = Keyword.get(opts, :sleep, &Process.sleep/1)
    on_retry = Keyword.get(opts, :on_retry, fn _, _, _ -> :ok end)

    delays = build_delay_schedule(opts, max_attempts)

    delays
    |> Enum.with_index(1)
    |> Enum.reduce_while(nil, fn {delay, attempt}, _ ->
      sleep_fn.(delay)

      case fun.() do
        {:ok, _} = success ->
          {:halt, success}

        {:error, reason} = error ->
          cond do
            retryable_error?(reason) and attempt < max_attempts ->
              next_delay = Enum.at(delays, attempt, 0)
              on_retry.(attempt, next_delay, reason)
              Emitter.emit_retry_scheduled(attempt, next_delay, reason)
              {:cont, error}

            retryable_error?(reason) and attempt >= max_attempts ->
              Emitter.emit_retry_exhausted(attempt, error)
              {:halt, error}

            true ->
              {:halt, error}
          end

        other ->
          {:halt, other}
      end
    end)
  end

  defp build_delay_schedule(opts, max_attempts) do
    base_delay = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    max_delay = Keyword.get(opts, :max_delay_ms, @default_max_delay_ms)
    jitter_pct = Keyword.get(opts, :jitter_percent, @default_jitter_percent) |> max(0)
    jitter_fraction = jitter_pct / 100

    backoff =
      exponential_backoff(base_delay)
      |> maybe_randomize(jitter_fraction)
      |> cap(max_delay)
      |> Enum.take(max_attempts - 1)

    [0 | backoff]
  end

  defp maybe_randomize(stream, fraction) when fraction <= 0, do: stream
  defp maybe_randomize(stream, fraction), do: randomize(stream, fraction)

  @doc false
  def retryable_error?({:transport_error, _}), do: true
  def retryable_error?(:timeout), do: true
  def retryable_error?({:http_error, status, _}) when status >= 500, do: true
  def retryable_error?({:http_error, 429, _}), do: true
  def retryable_error?(_), do: false
end
