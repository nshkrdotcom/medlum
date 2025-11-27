defmodule Lumainus.Conversion.Infrastructure.BackendRouterTest do
  use Lumainus.Conversion.TestCase

  alias Lumainus.Conversion.Infrastructure.BackendRouter
  alias Lumainus.Conversion.Infrastructure.HealthManager
  alias Lumainus.Conversion.Infrastructure.Resilience.CircuitBreaker

  @moduletag :capture_log

  describe "backends_for_profile/1" do
    test ":standard returns CPU backends" do
      backends = BackendRouter.backends_for_profile(:standard)

      backend_names = Enum.map(backends, & &1.name)
      assert :local_cpu in backend_names
      assert :docker_cpu in backend_names

      # Should NOT include GPU or cloud
      refute :local_gpu in backend_names
      refute :docker_gpu in backend_names
      refute :cloud in backend_names
    end

    test ":enhanced returns GPU and cloud backends" do
      backends = BackendRouter.backends_for_profile(:enhanced)

      backend_names = Enum.map(backends, & &1.name)
      assert :local_gpu in backend_names
      assert :docker_gpu in backend_names
      assert :cloud in backend_names

      # Should NOT include CPU backends
      refute :local_cpu in backend_names
      refute :docker_cpu in backend_names
    end

    test "returns backends with required fields" do
      backends = BackendRouter.backends_for_profile(:standard)

      for backend <- backends do
        assert is_atom(backend.name)
        assert is_atom(backend.module)
        assert is_binary(backend.endpoint) or is_nil(backend.endpoint)
        assert backend.backend_type in [:local, :cloud]
      end
    end
  end

  describe "route/1" do
    setup do
      # Start the required infrastructure for routing
      health_name = unique_name(:health_manager)
      registry_name = unique_name(:registry)

      # Start a Registry for circuit breakers
      {:ok, _} = start_supervised({Registry, keys: :unique, name: registry_name})

      # Start HealthManager with test backends
      backends = %{
        local_cpu: %{
          module: Lumainus.Conversion.Backends.LocalBackend,
          backend_type: :local,
          endpoint: "http://localhost:8040"
        },
        docker_cpu: %{
          module: Lumainus.Conversion.Backends.LocalBackend,
          backend_type: :local,
          endpoint: "http://localhost:8042"
        },
        local_gpu: %{
          module: Lumainus.Conversion.Backends.LocalBackend,
          backend_type: :local,
          endpoint: "http://localhost:8041"
        },
        docker_gpu: %{
          module: Lumainus.Conversion.Backends.LocalBackend,
          backend_type: :local,
          endpoint: "http://localhost:8043"
        },
        cloud: %{
          module: Lumainus.Conversion.Backends.CloudBackend,
          backend_type: :cloud,
          endpoint: "http://cloud.example.com"
        }
      }

      {:ok, _} =
        start_supervised({HealthManager, name: health_name, backends: backends})

      %{health_name: health_name, registry_name: registry_name}
    end

    test "returns {:ok, backend_info} when backends are available", %{health_name: health_name} do
      # Set up healthy backends
      :sys.replace_state(health_name, fn state ->
        health_states =
          Map.new([:local_cpu, :docker_cpu], fn name ->
            {name,
             %{
               status: :healthy,
               latency_ms: 50,
               checked_at: System.monotonic_time(:millisecond)
             }}
          end)

        %{state | health_states: health_states}
      end)

      result = BackendRouter.route(:standard, health_manager: health_name)

      assert {:ok, backend} = result
      assert backend.name in [:local_cpu, :docker_cpu]
      assert backend.backend_type == :local
    end

    test "filters out unhealthy backends", %{health_name: health_name} do
      # Make local_cpu unhealthy, docker_cpu healthy
      :sys.replace_state(health_name, fn state ->
        health_states = %{
          local_cpu: %{
            status: :unhealthy,
            latency_ms: nil,
            checked_at: System.monotonic_time(:millisecond)
          },
          docker_cpu: %{
            status: :healthy,
            latency_ms: 50,
            checked_at: System.monotonic_time(:millisecond)
          }
        }

        %{state | health_states: health_states}
      end)

      {:ok, backend} = BackendRouter.route(:standard, health_manager: health_name)

      # Should select the healthy backend
      assert backend.name == :docker_cpu
    end

    test "filters out backends with open circuit breakers", %{
      health_name: health_name,
      registry_name: _registry_name
    } do
      # Set all backends healthy
      :sys.replace_state(health_name, fn state ->
        health_states = %{
          local_cpu: %{
            status: :healthy,
            latency_ms: 50,
            checked_at: System.monotonic_time(:millisecond)
          },
          docker_cpu: %{
            status: :healthy,
            latency_ms: 60,
            checked_at: System.monotonic_time(:millisecond)
          }
        }

        %{state | health_states: health_states}
      end)

      # Open circuit for local_cpu
      {:ok, breaker_pid} =
        start_supervised({CircuitBreaker, backend_name: :local_cpu, name: nil})

      # Trip the breaker
      for _ <- 1..5 do
        CircuitBreaker.record_failure(breaker_pid, {:http_error, 500, %{}})
      end

      assert CircuitBreaker.state(breaker_pid) == :open

      {:ok, backend} =
        BackendRouter.route(:standard,
          health_manager: health_name,
          circuit_breaker_fn: fn name ->
            if name == :local_cpu, do: CircuitBreaker.state(breaker_pid), else: :closed
          end
        )

      # Should select the backend without open circuit
      assert backend.name == :docker_cpu
    end

    test "sorts by breaker state (closed=0, half_open=1), then latency", %{
      health_name: health_name
    } do
      # Set backends with different latencies
      :sys.replace_state(health_name, fn state ->
        health_states = %{
          local_cpu: %{
            status: :healthy,
            latency_ms: 100,
            checked_at: System.monotonic_time(:millisecond)
          },
          docker_cpu: %{
            status: :healthy,
            latency_ms: 50,
            checked_at: System.monotonic_time(:millisecond)
          }
        }

        %{state | health_states: health_states}
      end)

      {:ok, backend} = BackendRouter.route(:standard, health_manager: health_name)

      # Should prefer lower latency
      assert backend.name == :docker_cpu
    end

    test "returns {:error, :service_unavailable} when all backends down", %{
      health_name: health_name
    } do
      # Make all backends unhealthy
      :sys.replace_state(health_name, fn state ->
        health_states = %{
          local_cpu: %{
            status: :unhealthy,
            latency_ms: nil,
            checked_at: System.monotonic_time(:millisecond)
          },
          docker_cpu: %{
            status: :unhealthy,
            latency_ms: nil,
            checked_at: System.monotonic_time(:millisecond)
          }
        }

        %{state | health_states: health_states}
      end)

      result = BackendRouter.route(:standard, health_manager: health_name)

      assert result == {:error, :service_unavailable}
    end

    test "allows unknown health status (gives benefit of doubt)", %{health_name: health_name} do
      # Don't set any health states (all unknown)
      result = BackendRouter.route(:standard, health_manager: health_name)

      # Should still return a backend (unknown is allowed)
      assert {:ok, backend} = result
      assert backend.name in [:local_cpu, :docker_cpu]
    end

    test "allows half_open breaker (for probing)", %{health_name: health_name} do
      # Set backends healthy
      :sys.replace_state(health_name, fn state ->
        health_states = %{
          local_cpu: %{
            status: :healthy,
            latency_ms: 50,
            checked_at: System.monotonic_time(:millisecond)
          },
          docker_cpu: %{
            status: :healthy,
            latency_ms: 60,
            checked_at: System.monotonic_time(:millisecond)
          }
        }

        %{state | health_states: health_states}
      end)

      {:ok, backend} =
        BackendRouter.route(:standard,
          health_manager: health_name,
          circuit_breaker_fn: fn name ->
            # local_cpu is half_open (recovering), docker_cpu is closed
            if name == :local_cpu, do: :half_open, else: :closed
          end
        )

      # Should prefer closed breaker over half_open
      assert backend.name == :docker_cpu
    end
  end

  # Helper
  defp unique_name(base) do
    :"#{base}_#{System.unique_integer([:positive])}"
  end
end
