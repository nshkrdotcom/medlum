defmodule Medlum.Conversion.Infrastructure.Telemetry.EmitterTest do
  use Medlum.Conversion.TestCase, async: false

  alias Medlum.Conversion.Infrastructure.Telemetry.Emitter

  @moduletag :capture_log

  setup do
    # Clean up any previous handlers
    :ok
  end

  describe "emit_job_submitted/1" do
    test "emits telemetry event" do
      handler_id = attach_handler([:medlum, :conversion, :job, :submitted])

      job = build_job(profile: :standard, backend_used: :docker_cpu)
      Emitter.emit_job_submitted(job)

      assert_receive {:telemetry, [:medlum, :conversion, :job, :submitted], %{count: 1},
                      %{profile: :standard, backend_type: :local}}

      detach_handler(handler_id)
    end
  end

  describe "emit_job_completed/1" do
    test "emits telemetry event with duration" do
      handler_id = attach_handler([:medlum, :conversion, :job, :completed])

      job =
        build_job(
          profile: :enhanced,
          backend_used: :cloud,
          submitted_at: DateTime.add(DateTime.utc_now(), -5000, :millisecond)
        )

      Emitter.emit_job_completed(job)

      assert_receive {:telemetry, [:medlum, :conversion, :job, :completed],
                      %{count: 1, duration_ms: duration},
                      %{profile: :enhanced, backend_type: :cloud}}

      assert duration >= 5000

      detach_handler(handler_id)
    end
  end

  describe "emit_job_failed/2" do
    test "emits telemetry event with error type" do
      handler_id = attach_handler([:medlum, :conversion, :job, :failed])

      job = build_job(profile: :standard, backend_used: :docker_cpu)
      Emitter.emit_job_failed(job, :timeout)

      assert_receive {:telemetry, [:medlum, :conversion, :job, :failed], %{count: 1},
                      %{profile: :standard, backend_type: :local, error_type: :timeout}}

      detach_handler(handler_id)
    end

    test "normalizes error types" do
      handler_id = attach_handler([:medlum, :conversion, :job, :failed])

      job = build_job(profile: :standard, backend_used: :docker_cpu)
      Emitter.emit_job_failed(job, {:http_error, 503, %{}})

      assert_receive {:telemetry, [:medlum, :conversion, :job, :failed], %{count: 1},
                      %{error_type: :server_error}}

      detach_handler(handler_id)
    end
  end

  describe "emit_job_progress/2" do
    test "emits only at 10% intervals" do
      handler_id = attach_handler([:medlum, :conversion, :job, :progress])

      job = build_job(profile: :standard, backend_used: :docker_cpu)

      # These should emit
      Emitter.emit_job_progress(job, 0)
      Emitter.emit_job_progress(job, 10)
      Emitter.emit_job_progress(job, 20)

      # These should NOT emit
      Emitter.emit_job_progress(job, 5)
      Emitter.emit_job_progress(job, 15)
      Emitter.emit_job_progress(job, 25)

      assert_receive {:telemetry, [:medlum, :conversion, :job, :progress], %{progress: 0}, _}
      assert_receive {:telemetry, [:medlum, :conversion, :job, :progress], %{progress: 10}, _}
      assert_receive {:telemetry, [:medlum, :conversion, :job, :progress], %{progress: 20}, _}

      # Should NOT receive 5, 15, 25
      refute_receive {:telemetry, [:medlum, :conversion, :job, :progress], %{progress: 5}, _}
      refute_receive {:telemetry, [:medlum, :conversion, :job, :progress], %{progress: 15}, _}

      detach_handler(handler_id)
    end
  end

  describe "emit_circuit_opened/1" do
    test "emits telemetry event" do
      handler_id = attach_handler([:medlum, :conversion, :circuit, :opened])

      Emitter.emit_circuit_opened(:docker_cpu)

      assert_receive {:telemetry, [:medlum, :conversion, :circuit, :opened], %{count: 1},
                      %{backend: :docker_cpu}}

      detach_handler(handler_id)
    end
  end

  describe "emit_circuit_closed/1" do
    test "emits telemetry event" do
      handler_id = attach_handler([:medlum, :conversion, :circuit, :closed])

      Emitter.emit_circuit_closed(:cloud)

      assert_receive {:telemetry, [:medlum, :conversion, :circuit, :closed], %{count: 1},
                      %{backend: :cloud}}

      detach_handler(handler_id)
    end
  end

  describe "emit_health_checked/2" do
    test "emits telemetry event with latency" do
      handler_id = attach_handler([:medlum, :conversion, :health, :checked])

      Emitter.emit_health_checked(:docker_gpu, 150)

      assert_receive {:telemetry, [:medlum, :conversion, :health, :checked], %{latency_ms: 150},
                      %{backend: :docker_gpu}}

      detach_handler(handler_id)
    end
  end

  describe "emit_http_request/4" do
    test "emits telemetry with status bucket" do
      handler_id = attach_handler([:medlum, :conversion, :http, :request])

      Emitter.emit_http_request(:post, 200, 100, :local)

      assert_receive {:telemetry, [:medlum, :conversion, :http, :request], %{duration_ms: 100},
                      %{method: :post, status_bucket: "2xx", backend_type: :local}}

      detach_handler(handler_id)
    end

    test "buckets 4xx status" do
      handler_id = attach_handler([:medlum, :conversion, :http, :request])

      Emitter.emit_http_request(:get, 404, 50, :cloud)

      assert_receive {:telemetry, _, _, %{status_bucket: "4xx"}}

      detach_handler(handler_id)
    end

    test "buckets 5xx status" do
      handler_id = attach_handler([:medlum, :conversion, :http, :request])

      Emitter.emit_http_request(:post, 500, 200, :local)

      assert_receive {:telemetry, _, _, %{status_bucket: "5xx"}}

      detach_handler(handler_id)
    end
  end

  # Helpers

  defp attach_handler(event_name) do
    handler_id = "test-handler-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      event_name,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  defp detach_handler(handler_id) do
    :telemetry.detach(handler_id)
  end

  defp build_job(attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      profile: :standard,
      backend_used: :docker_cpu,
      submitted_at: DateTime.utc_now()
    }

    struct(Medlum.Conversion.Job, Map.merge(defaults, Map.new(attrs)))
  end
end
