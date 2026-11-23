defmodule Medlum.Conversion.Infrastructure.Resilience.RetryPolicyTest do
  use Medlum.Conversion.TestCase

  alias Medlum.Conversion.Infrastructure.Resilience.RetryPolicy

  @moduletag :capture_log

  describe "with_retry/2" do
    test "returns success immediately and only sleeps once" do
      parent = self()

      sleep = fn delay ->
        send(parent, {:slept, delay})
        :ok
      end

      assert {:ok, :result} = RetryPolicy.with_retry(fn -> {:ok, :result} end, sleep: sleep)

      assert_receive {:slept, 0}
      refute_receive {:slept, _}, 50
    end

    test "retries retryable errors with exponential backoff and on_retry callbacks" do
      parent = self()
      counter = :counters.new(1, [])

      sleep = fn delay ->
        send(parent, {:slept, delay})
        :ok
      end

      on_retry = fn attempt, delay, reason ->
        send(parent, {:retrying, attempt, delay, reason})
      end

      assert {:ok, "recovered"} =
               RetryPolicy.with_retry(
                 fn ->
                   :counters.add(counter, 1, 1)
                   attempt = :counters.get(counter, 1)

                   if attempt < 3 do
                     {:error, {:transport_error, :econnrefused}}
                   else
                     {:ok, "recovered"}
                   end
                 end,
                 base_delay_ms: 10,
                 jitter_percent: 0,
                 max_attempts: 3,
                 sleep: sleep,
                 on_retry: on_retry
               )

      assert_receive {:slept, 0}
      assert_receive {:retrying, 1, 10, {:transport_error, :econnrefused}}
      assert_receive {:slept, 10}
      assert_receive {:retrying, 2, 20, {:transport_error, :econnrefused}}
      assert_receive {:slept, 20}
      refute_receive {:retrying, 3, _, _}, 10
    end

    test "does not retry non-retryable errors" do
      parent = self()

      on_retry = fn attempt, delay, reason ->
        send(parent, {:retry, attempt, delay, reason})
      end

      sleep = fn delay ->
        send(parent, {:slept, delay})
        :ok
      end

      assert {:error, {:http_error, 400, %{}}} =
               RetryPolicy.with_retry(
                 fn -> {:error, {:http_error, 400, %{}}} end,
                 base_delay_ms: 5,
                 sleep: sleep,
                 on_retry: on_retry
               )

      assert_receive {:slept, 0}
      refute_receive {:retry, _, _, _}, 50
      refute_receive {:slept, _}, 50
    end

    test "emits telemetry for scheduled retries and exhaustion" do
      scheduled_handler =
        attach_telemetry_handler([:medlum, :conversion, :retry, :scheduled])

      exhausted_handler =
        attach_telemetry_handler([:medlum, :conversion, :retry, :exhausted])

      result =
        RetryPolicy.with_retry(
          fn -> {:error, {:http_error, 503, %{}}} end,
          base_delay_ms: 1,
          jitter_percent: 0,
          max_attempts: 2,
          sleep: fn _ -> :ok end
        )

      assert {:error, {:http_error, 503, _}} = result

      assert_telemetry_event([:medlum, :conversion, :retry, :scheduled])
      assert_telemetry_event([:medlum, :conversion, :retry, :exhausted])

      detach_telemetry_handler(scheduled_handler)
      detach_telemetry_handler(exhausted_handler)
    end

    test "caps backoff and supports custom sleep function" do
      parent = self()

      _ =
        RetryPolicy.with_retry(
          fn -> {:error, {:transport_error, :timeout}} end,
          base_delay_ms: 1_000,
          max_delay_ms: 2_000,
          jitter_percent: 0,
          max_attempts: 4,
          sleep: fn delay ->
            send(parent, {:slept, delay})
            :ok
          end
        )

      assert_receive {:slept, 0}
      assert_receive {:slept, 1_000}
      assert_receive {:slept, 2_000}
      assert_receive {:slept, 2_000}
    end
  end

  describe "retryable_error?/1" do
    test "treats retry-safe errors as retryable" do
      assert RetryPolicy.retryable_error?({:transport_error, :econnrefused})
      assert RetryPolicy.retryable_error?(:timeout)
      assert RetryPolicy.retryable_error?({:http_error, 500, %{}})
      assert RetryPolicy.retryable_error?({:http_error, 503, %{}})
      assert RetryPolicy.retryable_error?({:http_error, 429, %{}})
    end

    test "treats client errors as non-retryable" do
      refute RetryPolicy.retryable_error?({:http_error, 400, %{}})
      refute RetryPolicy.retryable_error?({:http_error, 404, %{}})
      refute RetryPolicy.retryable_error?({:http_error, 422, %{}})
      refute RetryPolicy.retryable_error?(:unknown)
    end
  end
end
