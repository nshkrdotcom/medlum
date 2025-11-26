# v2 Testing Strategy

**Date:** November 26, 2025

---

## Overview

The v2 architecture is designed for testability from the ground up:

1. **Behavior contracts** - Every external dependency has a behavior
2. **Dependency injection** - Implementations configurable per environment
3. **Test doubles** - Mock/stub implementations for all behaviors
4. **Property-based tests** - State machines and resilience patterns

---

## Testing Pyramid

```
                    ┌─────────────┐
                    │   E2E       │  Few: Full system with real Docling
                    │   Tests     │
                    └──────┬──────┘
                           │
                    ┌──────┴──────┐
                    │ Integration │  Some: Multiple components, mock HTTP
                    │   Tests     │
                    └──────┬──────┘
                           │
              ┌────────────┴────────────┐
              │       Unit Tests         │  Many: Single components, all mocked
              │                          │
              └──────────────────────────┘
```

---

## Behavior Contracts

### Backend Behavior

```elixir
defmodule Lumainus.Conversion.Infrastructure.Backend do
  @moduledoc "Contract for conversion backends"

  @callback convert(binary(), Job.t()) :: {:ok, map()} | {:error, term()}
  @callback enqueue(binary(), Job.t()) :: {:ok, String.t()} | {:error, term()}
  @callback await(String.t(), non_neg_integer(), (JobStatus.t() -> any())) :: {:ok, map()} | {:error, term()}
  @callback status(String.t()) :: {:ok, map()} | {:error, term()}
  @callback cancel(String.t()) :: :ok | {:error, term()}
  @callback health() :: {:ok, map()} | {:error, term()}
  @callback name() :: atom()
end
```

### HTTP Client Behavior

```elixir
defmodule Lumainus.Conversion.Infrastructure.HttpClient do
  @moduledoc "Contract for HTTP operations"

  @callback request(method :: atom(), url :: String.t(), opts :: keyword()) ::
    {:ok, %{status: integer(), body: binary()}} | {:error, term()}

  @callback stream(method :: atom(), url :: String.t(), opts :: keyword(), callback :: fun()) ::
    {:ok, term()} | {:error, term()}
end
```

### Health Manager Behavior

```elixir
defmodule Lumainus.Conversion.Infrastructure.HealthChecker do
  @moduledoc "Contract for health checking"

  @callback healthy?(backend :: atom()) :: boolean()
  @callback latency(backend :: atom()) :: non_neg_integer() | :infinity
  @callback check_now(backend :: atom()) :: :ok
end
```

---

## Test Configuration

```elixir
# config/test.exs

config :lumainus, Lumainus.Conversion,
  # Use mock backends in tests
  backend_module: Lumainus.Conversion.Test.MockBackend,
  http_client: Lumainus.Conversion.Test.MockHttpClient,
  health_checker: Lumainus.Conversion.Test.MockHealthChecker,

  # Disable background processes
  enable_health_checks: false,
  enable_circuit_breaker_timers: false,

  # Fast timeouts for tests
  default_timeout_ms: 5_000,
  poll_interval_ms: 100
```

---

## Mock Implementations

### Mock Backend

```elixir
defmodule Lumainus.Conversion.Test.MockBackend do
  @moduledoc """
  Configurable mock backend for testing.
  """

  @behaviour Lumainus.Conversion.Infrastructure.Backend

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{responses: %{}, calls: []} end, name: __MODULE__)
  end

  # Test Setup API

  @doc "Configure response for next call"
  def set_response(operation, response) do
    Agent.update(__MODULE__, fn state ->
      put_in(state, [:responses, operation], response)
    end)
  end

  @doc "Configure error for next call"
  def set_error(operation, error) do
    set_response(operation, {:error, error})
  end

  @doc "Get recorded calls"
  def get_calls do
    Agent.get(__MODULE__, & &1.calls)
  end

  @doc "Clear state"
  def reset do
    Agent.update(__MODULE__, fn _ -> %{responses: %{}, calls: []} end)
  end

  # Backend Implementation

  @impl true
  def convert(binary, job) do
    record_call(:convert, {binary, job})
    get_response(:convert, default_convert_response())
  end

  @impl true
  def enqueue(binary, job) do
    record_call(:enqueue, {binary, job})
    get_response(:enqueue, {:ok, "mock-job-id"})
  end

  @impl true
  def await(job_id, timeout, on_progress) do
    record_call(:await, {job_id, timeout, on_progress})
    get_response(:await, default_convert_response())
  end

  @impl true
  def status(job_id) do
    record_call(:status, job_id)
    get_response(:status, {:ok, %{"state" => "completed", "progress" => 100}})
  end

  @impl true
  def cancel(job_id) do
    record_call(:cancel, job_id)
    get_response(:cancel, :ok)
  end

  @impl true
  def health do
    record_call(:health, nil)
    get_response(:health, {:ok, %{"status" => "healthy"}})
  end

  @impl true
  def name, do: :mock

  # Private

  defp record_call(operation, args) do
    Agent.update(__MODULE__, fn state ->
      update_in(state.calls, &[{operation, args, System.monotonic_time()} | &1])
    end)
  end

  defp get_response(operation, default) do
    Agent.get(__MODULE__, fn state ->
      Map.get(state.responses, operation, default)
    end)
  end

  defp default_convert_response do
    {:ok, %{
      "markdown" => "# Test Document\n\nTest content.",
      "metadata" => %{"page_count" => 1}
    }}
  end
end
```

### Mock HTTP Client

```elixir
defmodule Lumainus.Conversion.Test.MockHttpClient do
  @moduledoc """
  Mock HTTP client with request recording.
  """

  @behaviour Lumainus.Conversion.Infrastructure.HttpClient

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{responses: [], requests: []} end, name: __MODULE__)
  end

  # Test Setup API

  @doc "Queue a response (FIFO)"
  def queue_response(response) do
    Agent.update(__MODULE__, fn state ->
      update_in(state.responses, &(&1 ++ [response]))
    end)
  end

  @doc "Queue multiple responses"
  def queue_responses(responses) do
    Enum.each(responses, &queue_response/1)
  end

  @doc "Get all recorded requests"
  def get_requests do
    Agent.get(__MODULE__, & &1.requests)
  end

  @doc "Reset state"
  def reset do
    Agent.update(__MODULE__, fn _ -> %{responses: [], requests: []} end)
  end

  # HttpClient Implementation

  @impl true
  def request(method, url, opts) do
    record_request(method, url, opts)
    pop_response()
  end

  @impl true
  def stream(method, url, opts, callback) do
    record_request(method, url, opts)

    case pop_response() do
      {:ok, %{status: status, body: body}} ->
        callback.({:status, status}, nil)
        callback.({:headers, []}, nil)
        callback.({:data, body}, nil)
        {:ok, nil}

      {:error, _} = error ->
        error
    end
  end

  # Private

  defp record_request(method, url, opts) do
    Agent.update(__MODULE__, fn state ->
      request = %{method: method, url: url, opts: opts, at: System.monotonic_time()}
      update_in(state.requests, &[request | &1])
    end)
  end

  defp pop_response do
    Agent.get_and_update(__MODULE__, fn state ->
      case state.responses do
        [response | rest] -> {response, %{state | responses: rest}}
        [] -> {{:error, :no_mock_response}, state}
      end
    end)
  end
end
```

---

## Unit Tests

### Service Tests

```elixir
defmodule Lumainus.Conversion.ServiceTest do
  use ExUnit.Case, async: true

  alias Lumainus.Conversion.Service
  alias Lumainus.Conversion.Test.MockBackend

  setup do
    start_supervised!(MockBackend)
    MockBackend.reset()
    :ok
  end

  describe "submit/2" do
    test "creates job and submits to backend" do
      MockBackend.set_response(:enqueue, {:ok, "job-123"})

      {:ok, job} = Service.submit(pdf_binary(), filename: "test.pdf")

      assert job.id
      assert job.profile == :standard
      assert job.filename == "test.pdf"

      # Verify backend was called
      calls = MockBackend.get_calls()
      assert [{:enqueue, {^pdf_binary, ^job}, _}] = Enum.filter(calls, &match?({:enqueue, _, _}, &1))
    end

    test "validates file type" do
      assert {:error, :invalid_file_type} = Service.submit(pdf_binary(), filename: "test.txt")
    end

    test "validates file size" do
      large_binary = :binary.copy(<<0>>, 200 * 1024 * 1024)  # 200 MB

      assert {:error, :file_too_large} = Service.submit(large_binary, filename: "huge.pdf")
    end

    test "validates PDF header" do
      assert {:error, :invalid_pdf} = Service.submit("not a pdf", filename: "fake.pdf")
    end

    test "handles backend errors" do
      MockBackend.set_error(:enqueue, :connection_refused)

      assert {:error, :connection_refused} = Service.submit(pdf_binary(), filename: "test.pdf")
    end
  end

  describe "status/1" do
    test "returns job status" do
      MockBackend.set_response(:status, {:ok, %{
        "state" => "processing",
        "progress" => 50,
        "pages_done" => 5,
        "pages_total" => 10
      }})

      {:ok, status} = Service.status("job-123")

      assert status.state == :processing
      assert status.progress == 50
      assert status.pages_done == 5
      assert status.pages_total == 10
    end

    test "normalizes backend state names" do
      MockBackend.set_response(:status, {:ok, %{"state" => "running"}})

      {:ok, status} = Service.status("job-123")
      assert status.state == :processing
    end
  end

  describe "cancel/1" do
    test "cancels job on backend" do
      MockBackend.set_response(:cancel, :ok)

      assert :ok = Service.cancel("job-123")

      calls = MockBackend.get_calls()
      assert Enum.any?(calls, &match?({:cancel, "job-123", _}, &1))
    end
  end

  # Helper

  defp pdf_binary do
    "%PDF-1.4 test content"
  end
end
```

### Circuit Breaker Tests

```elixir
defmodule Lumainus.Conversion.Infrastructure.CircuitBreakerTest do
  use ExUnit.Case, async: true

  alias Lumainus.Conversion.Infrastructure.CircuitBreaker

  setup do
    # Start circuit breaker for test backend
    start_supervised!({CircuitBreaker, backend: :test_backend})
    :ok
  end

  describe "state transitions" do
    test "starts closed" do
      assert CircuitBreaker.state(:test_backend) == :closed
      assert CircuitBreaker.available?(:test_backend) == true
    end

    test "opens after threshold failures" do
      # Simulate 5 failures
      for _ <- 1..5 do
        CircuitBreaker.call(:test_backend, fn -> {:error, :failure} end)
      end

      assert CircuitBreaker.state(:test_backend) == :open
      assert CircuitBreaker.available?(:test_backend) == false
    end

    test "rejects calls when open" do
      CircuitBreaker.trip(:test_backend)

      assert {:error, :circuit_open} = CircuitBreaker.call(:test_backend, fn -> {:ok, :result} end)
    end

    test "transitions to half-open after timeout" do
      CircuitBreaker.trip(:test_backend)

      # Wait for timeout (configured to be short in tests)
      Process.sleep(100)

      assert CircuitBreaker.state(:test_backend) == :half_open
    end

    test "closes after successful calls in half-open" do
      CircuitBreaker.trip(:test_backend)
      Process.sleep(100)  # Wait for half-open

      # Successful calls close the circuit
      for _ <- 1..3 do
        CircuitBreaker.call(:test_backend, fn -> {:ok, :result} end)
      end

      assert CircuitBreaker.state(:test_backend) == :closed
    end

    test "reopens on failure in half-open" do
      CircuitBreaker.trip(:test_backend)
      Process.sleep(100)  # Wait for half-open

      CircuitBreaker.call(:test_backend, fn -> {:error, :failure} end)

      assert CircuitBreaker.state(:test_backend) == :open
    end
  end

  describe "success counting" do
    test "resets failure count on success" do
      # 4 failures
      for _ <- 1..4 do
        CircuitBreaker.call(:test_backend, fn -> {:error, :failure} end)
      end

      # Success resets count
      CircuitBreaker.call(:test_backend, fn -> {:ok, :result} end)

      # 4 more failures should not open (count was reset)
      for _ <- 1..4 do
        CircuitBreaker.call(:test_backend, fn -> {:error, :failure} end)
      end

      assert CircuitBreaker.state(:test_backend) == :closed
    end
  end
end
```

### Retry Policy Tests

```elixir
defmodule Lumainus.Conversion.Infrastructure.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias Lumainus.Conversion.Infrastructure.RetryPolicy

  describe "with_retry/2" do
    test "returns success without retry" do
      result = RetryPolicy.with_retry(fn -> {:ok, :result} end)
      assert result == {:ok, :result}
    end

    test "retries on retryable error" do
      counter = :counters.new(1, [:atomics])

      result = RetryPolicy.with_retry(
        fn ->
          count = :counters.add(counter, 1, 1)
          if :counters.get(counter, 1) < 3 do
            {:error, :timeout}
          else
            {:ok, :result}
          end
        end,
        max_attempts: 5,
        base_delay_ms: 1  # Fast for tests
      )

      assert result == {:ok, :result}
      assert :counters.get(counter, 1) == 3
    end

    test "gives up after max attempts" do
      counter = :counters.new(1, [:atomics])

      result = RetryPolicy.with_retry(
        fn ->
          :counters.add(counter, 1, 1)
          {:error, :timeout}
        end,
        max_attempts: 3,
        base_delay_ms: 1
      )

      assert result == {:error, :timeout}
      assert :counters.get(counter, 1) == 3
    end

    test "does not retry non-retryable errors" do
      counter = :counters.new(1, [:atomics])

      result = RetryPolicy.with_retry(
        fn ->
          :counters.add(counter, 1, 1)
          {:error, {:http_error, 400, "bad request"}}
        end,
        max_attempts: 3
      )

      assert {:error, {:http_error, 400, _}} = result
      assert :counters.get(counter, 1) == 1  # No retry
    end

    test "applies exponential backoff" do
      delays = []

      RetryPolicy.with_retry(
        fn ->
          {:error, :timeout}
        end,
        max_attempts: 4,
        base_delay_ms: 100,
        jitter_factor: 0  # No jitter for predictable test
      )

      # Would verify delays are ~100, ~200, ~400
      # In practice, measure elapsed time between attempts
    end
  end
end
```

---

## Property-Based Tests

### Circuit Breaker State Machine

```elixir
defmodule Lumainus.Conversion.Infrastructure.CircuitBreakerPropertyTest do
  use ExUnit.Case
  use PropCheck

  alias Lumainus.Conversion.Infrastructure.CircuitBreaker

  property "circuit breaker state machine is consistent" do
    forall commands <- commands(__MODULE__) do
      {:ok, pid} = CircuitBreaker.start_link(backend: :prop_test)

      {_history, _state, result} = run_commands(__MODULE__, commands)

      GenServer.stop(pid)

      result == :ok
    end
  end

  # State machine model

  def initial_state, do: %{state: :closed, failures: 0, successes: 0}

  def command(_state) do
    oneof([
      {:call, CircuitBreaker, :call, [:prop_test, success_fn()]},
      {:call, CircuitBreaker, :call, [:prop_test, failure_fn()]},
      {:call, CircuitBreaker, :trip, [:prop_test]},
      {:call, CircuitBreaker, :reset, [:prop_test]}
    ])
  end

  def precondition(_state, _call), do: true

  def postcondition(state, {:call, _, :call, [_, fun]}, result) do
    case {state.state, fun.(), result} do
      {:open, _, {:error, :circuit_open}} -> true
      {:closed, {:ok, _}, {:ok, _}} -> true
      {:closed, {:error, _}, {:error, _}} -> true
      {:half_open, {:ok, _}, {:ok, _}} -> true
      {:half_open, {:error, _}, {:error, _}} -> true
      _ -> false
    end
  end

  def postcondition(_state, {:call, _, :trip, _}, :ok), do: true
  def postcondition(_state, {:call, _, :reset, _}, :ok), do: true

  def next_state(state, _result, {:call, _, :call, [_, fun]}) do
    case {state.state, fun.()} do
      {:closed, {:error, _}} ->
        new_failures = state.failures + 1
        if new_failures >= 5 do
          %{state | state: :open, failures: new_failures}
        else
          %{state | failures: new_failures}
        end

      {:closed, {:ok, _}} ->
        %{state | failures: 0}

      {:half_open, {:ok, _}} ->
        new_successes = state.successes + 1
        if new_successes >= 3 do
          %{state | state: :closed, failures: 0, successes: 0}
        else
          %{state | successes: new_successes}
        end

      {:half_open, {:error, _}} ->
        %{state | state: :open, successes: 0}

      _ ->
        state
    end
  end

  def next_state(state, _result, {:call, _, :trip, _}) do
    %{state | state: :open}
  end

  def next_state(state, _result, {:call, _, :reset, _}) do
    %{state | state: :closed, failures: 0, successes: 0}
  end

  defp success_fn, do: fn -> {:ok, :result} end
  defp failure_fn, do: fn -> {:error, :failure} end
end
```

---

## Integration Tests

```elixir
defmodule Lumainus.Conversion.IntegrationTest do
  use ExUnit.Case

  alias Lumainus.Conversion.Service
  alias Lumainus.Conversion.Test.{MockBackend, MockHttpClient}

  @moduletag :integration

  setup do
    start_supervised!(MockBackend)
    start_supervised!(MockHttpClient)
    MockBackend.reset()
    MockHttpClient.reset()
    :ok
  end

  describe "full conversion flow" do
    test "submit -> status -> await" do
      # Setup mock responses
      MockBackend.set_response(:enqueue, {:ok, "job-123"})
      MockBackend.set_response(:status, {:ok, %{"state" => "processing", "progress" => 50}})
      MockBackend.set_response(:await, {:ok, %{"markdown" => "# Result", "metadata" => %{}}})

      # Submit job
      {:ok, job} = Service.submit(pdf_binary(), filename: "test.pdf")
      assert job.id

      # Check status
      {:ok, status} = Service.status(job.id)
      assert status.state == :processing

      # Await completion
      {:ok, result} = Service.await(job.id, timeout_ms: 5_000)
      assert result["markdown"] == "# Result"
    end

    test "handles backend failure gracefully" do
      MockBackend.set_error(:enqueue, :connection_refused)

      {:error, reason} = Service.submit(pdf_binary(), filename: "test.pdf")
      assert reason == :connection_refused
    end

    test "cancellation stops processing" do
      MockBackend.set_response(:enqueue, {:ok, "job-123"})
      MockBackend.set_response(:cancel, :ok)

      {:ok, job} = Service.submit(pdf_binary(), filename: "test.pdf")
      :ok = Service.cancel(job.id)

      # Verify cancel was called
      calls = MockBackend.get_calls()
      assert Enum.any?(calls, &match?({:cancel, _, _}, &1))
    end
  end

  defp pdf_binary, do: "%PDF-1.4 test content"
end
```

---

## Test Helpers

```elixir
defmodule Lumainus.Conversion.Test.Helpers do
  @moduledoc """
  Test helpers for conversion tests.
  """

  @doc "Generate a minimal valid PDF binary"
  def pdf_binary(content \\ "test") do
    "%PDF-1.4\n#{content}\n%%EOF"
  end

  @doc "Generate a PDF of specific size"
  def pdf_of_size(bytes) do
    padding = :binary.copy(<<0>>, bytes - 20)
    "%PDF-1.4\n#{padding}\n%%EOF"
  end

  @doc "Create a test job"
  def test_job(attrs \\ %{}) do
    Lumainus.Conversion.Job.new(
      Map.merge(%{
        profile: :standard,
        filename: "test.pdf",
        byte_size: 1024,
        tenant_id: "test-tenant",
        user_id: "test-user"
      }, attrs)
    )
  end

  @doc "Wait for telemetry event"
  def wait_for_telemetry(event_name, timeout \\ 1_000) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      ref,
      event_name,
      fn name, measurements, metadata, _ ->
        send(parent, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    receive do
      {:telemetry, ^event_name, measurements, metadata} ->
        :telemetry.detach(ref)
        {:ok, measurements, metadata}
    after
      timeout ->
        :telemetry.detach(ref)
        {:error, :timeout}
    end
  end
end
```

---

## Test Coverage Goals

| Component | Unit | Integration | Property |
|-----------|------|-------------|----------|
| Service | 100% | 80% | - |
| Job | 100% | - | - |
| JobStatus | 100% | - | - |
| Policy | 100% | - | - |
| CircuitBreaker | 100% | - | 100% |
| RetryPolicy | 100% | - | - |
| BackendRouter | 90% | 80% | - |
| HealthManager | 90% | 70% | - |
| SSEStream | 80% | 60% | - |
| Telemetry | 90% | - | - |

---

## Next: UI Abstraction

See [05-ui-abstraction.md](05-ui-abstraction.md) for complete UI decoupling.
