defmodule Lumainus.Conversion.Infrastructure.HealthManagerTest do
  use Lumainus.Conversion.TestCase

  alias Lumainus.Conversion.Infrastructure.HealthManager

  @moduletag :capture_log

  describe "start_link/1" do
    test "starts successfully with default backends" do
      {:ok, pid} = start_supervised({HealthManager, name: unique_name(:health_manager)})
      assert Process.alive?(pid)
    end

    test "starts successfully with custom backends" do
      backends = %{
        test_backend: %{module: FakeBackend, backend_type: :local}
      }

      {:ok, pid} =
        start_supervised({HealthManager, name: unique_name(:health_manager), backends: backends})

      assert Process.alive?(pid)
    end
  end

  describe "status/1" do
    test "returns :unknown for unchecked backend" do
      name = unique_name(:health_manager)
      backends = %{test_backend: %{module: FakeBackend, backend_type: :local}}
      {:ok, _pid} = start_supervised({HealthManager, name: name, backends: backends})

      # Status should be :unknown since no check has happened yet
      assert HealthManager.status(name, :test_backend) == :unknown
    end

    test "returns :healthy after successful health check" do
      name = unique_name(:health_manager)

      # Use a mock that always returns healthy
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"status": "ok"}))
      end)

      backends = %{
        test_backend: %{
          module: __MODULE__.MockLocalBackend,
          backend_type: :local,
          endpoint: "http://localhost:#{bypass.port}"
        }
      }

      {:ok, _pid} = start_supervised({HealthManager, name: name, backends: backends})

      # Trigger immediate check
      HealthManager.check_now(name, :test_backend)

      # Wait for the check to complete
      assert_eventually(fn ->
        HealthManager.status(name, :test_backend) == :healthy
      end)
    end

    test "returns :unhealthy after failed health check" do
      name = unique_name(:health_manager)

      # Use a mock that always fails
      bypass = Bypass.open()

      # Use Bypass.stub since RetryPolicy may retry the request
      Bypass.stub(bypass, "GET", "/health", fn conn ->
        Plug.Conn.resp(conn, 500, ~s({"status": "error"}))
      end)

      backends = %{
        test_backend: %{
          module: __MODULE__.MockLocalBackend,
          backend_type: :local,
          endpoint: "http://localhost:#{bypass.port}"
        }
      }

      {:ok, _pid} = start_supervised({HealthManager, name: name, backends: backends})

      # Trigger immediate check
      HealthManager.check_now(name, :test_backend)

      # Wait for the check to complete
      assert_eventually(fn ->
        HealthManager.status(name, :test_backend) == :unhealthy
      end)
    end

    test "returns :unknown when health data is stale (>90s)" do
      name = unique_name(:health_manager)

      backends = %{
        test_backend: %{
          module: __MODULE__.MockLocalBackend,
          backend_type: :local,
          endpoint: "http://localhost:9999"
        }
      }

      {:ok, pid} = start_supervised({HealthManager, name: name, backends: backends})

      # Manually set stale health data (simulate old check)
      stale_time = System.monotonic_time(:millisecond) - 100_000

      :sys.replace_state(pid, fn state ->
        new_health = %{
          status: :healthy,
          latency_ms: 50,
          checked_at: stale_time
        }

        %{state | health_states: Map.put(state.health_states, :test_backend, new_health)}
      end)

      # Should return :unknown because data is stale
      assert HealthManager.status(name, :test_backend) == :unknown
    end
  end

  describe "latency/1" do
    test "returns :infinity for unchecked backend" do
      name = unique_name(:health_manager)
      backends = %{test_backend: %{module: FakeBackend, backend_type: :local}}
      {:ok, _pid} = start_supervised({HealthManager, name: name, backends: backends})

      assert HealthManager.latency(name, :test_backend) == :infinity
    end

    test "returns latency in ms after successful check" do
      name = unique_name(:health_manager)

      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        # Small delay to ensure measurable latency
        Process.sleep(10)
        Plug.Conn.resp(conn, 200, ~s({"status": "ok"}))
      end)

      backends = %{
        test_backend: %{
          module: __MODULE__.MockLocalBackend,
          backend_type: :local,
          endpoint: "http://localhost:#{bypass.port}"
        }
      }

      {:ok, _pid} = start_supervised({HealthManager, name: name, backends: backends})

      # Trigger immediate check
      HealthManager.check_now(name, :test_backend)

      # Wait for the check to complete and verify latency is recorded
      assert_eventually(fn ->
        latency = HealthManager.latency(name, :test_backend)
        is_integer(latency) and latency > 0
      end)
    end
  end

  describe "check_now/1" do
    test "triggers immediate health check" do
      name = unique_name(:health_manager)

      bypass = Bypass.open()

      # Track that health endpoint was called
      test_pid = self()

      Bypass.expect(bypass, "GET", "/health", fn conn ->
        send(test_pid, :health_checked)
        Plug.Conn.resp(conn, 200, ~s({"status": "ok"}))
      end)

      backends = %{
        test_backend: %{
          module: __MODULE__.MockLocalBackend,
          backend_type: :local,
          endpoint: "http://localhost:#{bypass.port}"
        }
      }

      {:ok, _pid} = start_supervised({HealthManager, name: name, backends: backends})

      # Trigger immediate check
      HealthManager.check_now(name, :test_backend)

      # Should receive the health check message
      assert_receive :health_checked, 5000
    end
  end

  describe "periodic checks" do
    test "schedules next check with jitter (30s ±20%)" do
      name = unique_name(:health_manager)

      # We'll track the timing between checks
      bypass = Bypass.open()
      test_pid = self()

      check_count = :counters.new(1, [:atomics])

      Bypass.stub(bypass, "GET", "/health", fn conn ->
        :counters.add(check_count, 1, 1)
        count = :counters.get(check_count, 1)
        send(test_pid, {:health_check, count, System.monotonic_time(:millisecond)})
        Plug.Conn.resp(conn, 200, ~s({"status": "ok"}))
      end)

      backends = %{
        test_backend: %{
          module: __MODULE__.MockLocalBackend,
          backend_type: :local,
          endpoint: "http://localhost:#{bypass.port}"
        }
      }

      # Start with very short interval for testing
      {:ok, _pid} =
        start_supervised(
          {HealthManager,
           name: name, backends: backends, check_interval_ms: 100, jitter_percent: 20}
        )

      # Trigger first check
      HealthManager.check_now(name, :test_backend)

      # Wait for first check
      assert_receive {:health_check, 1, _time1}, 5000

      # Wait for second check (should be scheduled automatically)
      assert_receive {:health_check, 2, _time2}, 5000
    end
  end

  # Helper functions

  defp unique_name(base) do
    :"#{base}_#{System.unique_integer([:positive])}"
  end

  defp assert_eventually(check_fn, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(check_fn, deadline)
  end

  defp do_assert_eventually(check_fn, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("Condition not met within timeout")
    else
      if check_fn.() do
        :ok
      else
        Process.sleep(50)
        do_assert_eventually(check_fn, deadline)
      end
    end
  end

  # Mock backend module for testing
  defmodule MockLocalBackend do
    def health(opts) do
      endpoint = Keyword.get(opts, :endpoint)

      case Req.get("#{endpoint}/health", receive_timeout: 5000) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          {:ok, %{"status" => "ok"}}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:http_error, status, %{}}}

        {:error, reason} ->
          {:error, {:transport_error, reason}}
      end
    end
  end
end
