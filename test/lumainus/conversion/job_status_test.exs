defmodule Lumainus.Conversion.JobStatusTest do
  use Lumainus.Conversion.TestCase

  alias Lumainus.Conversion.Job
  alias Lumainus.Conversion.JobStatus

  describe "from_job/1" do
    test "creates JobStatus from Job record" do
      job =
        build_job(%{
          id: Ecto.UUID.generate(),
          profile: :standard,
          filename: "test.pdf",
          byte_size: 1024,
          state: :processing,
          progress: 50,
          pages_total: 10,
          pages_done: 5,
          backend_used: :docker_cpu,
          backend_endpoint: "http://localhost:8042",
          instance_id: nil,
          updated_at: DateTime.utc_now()
        })

      status = JobStatus.from_job(job)

      assert status.job_id == job.id
      assert status.state == :processing
      assert status.progress == 50
      assert status.pages_total == 10
      assert status.pages_done == 5
      assert status.backend_used == :docker_cpu
      assert status.backend_endpoint == "http://localhost:8042"
    end

    test "handles nil progress as 0" do
      job =
        build_job(%{
          state: :queued,
          progress: nil
        })

      status = JobStatus.from_job(job)

      assert status.progress == 0
    end

    test "handles nil pages_done as 0" do
      job =
        build_job(%{
          state: :processing,
          pages_done: nil
        })

      status = JobStatus.from_job(job)

      assert status.pages_done == 0
    end

    test "includes result when completed" do
      result = %{"markdown" => "# Test", "metadata" => %{}}

      job =
        build_job(%{
          state: :completed,
          result: result
        })

      status = JobStatus.from_job(job)

      assert status.state == :completed
      assert status.result == result
    end

    test "includes error when failed" do
      job =
        build_job(%{
          state: :failed,
          last_error: "Connection timeout"
        })

      status = JobStatus.from_job(job)

      assert status.state == :failed
      assert status.error == "Connection timeout"
    end

    test "sets processed_at when completed" do
      now = DateTime.utc_now()

      job =
        build_job(%{
          state: :completed,
          updated_at: now
        })

      status = JobStatus.from_job(job)

      assert status.processed_at == now
    end

    test "processed_at is nil when not completed" do
      job =
        build_job(%{
          state: :processing,
          updated_at: DateTime.utc_now()
        })

      status = JobStatus.from_job(job)

      assert status.processed_at == nil
    end

    test "includes message based on state" do
      states_with_messages = [
        {:queued, "Waiting in queue..."},
        {:provisioning, "Starting GPU instance..."},
        {:starting, "Initializing processor..."},
        {:processing, "Converting document..."},
        {:completed, "Conversion complete"},
        {:failed, "Conversion failed"},
        {:cancelled, "Cancelled"},
        {:timeout, "Timed out"}
      ]

      for {state, expected_message} <- states_with_messages do
        job = build_job(%{state: state})
        status = JobStatus.from_job(job)

        assert status.message == expected_message,
               "Expected message '#{expected_message}' for state #{state}, got '#{status.message}'"
      end
    end

    test "includes cloud instance_id when present" do
      job =
        build_job(%{
          backend_used: :cloud,
          backend_endpoint: "https://gpu.example.com",
          instance_id: 12345
        })

      status = JobStatus.from_job(job)

      assert status.backend_used == :cloud
      assert status.instance_id == 12345
    end
  end

  describe "normalize_state/1" do
    test "normalizes 'queued' to :queued" do
      assert JobStatus.normalize_state("queued") == :queued
    end

    test "normalizes 'loading' to :provisioning" do
      assert JobStatus.normalize_state("loading") == :provisioning
    end

    test "normalizes 'starting' to :starting" do
      assert JobStatus.normalize_state("starting") == :starting
    end

    test "normalizes 'running' to :processing" do
      assert JobStatus.normalize_state("running") == :processing
    end

    test "normalizes 'processing' to :processing" do
      assert JobStatus.normalize_state("processing") == :processing
    end

    test "normalizes 'completed' to :completed" do
      assert JobStatus.normalize_state("completed") == :completed
    end

    test "normalizes 'failed' to :failed" do
      assert JobStatus.normalize_state("failed") == :failed
    end

    test "normalizes 'cancelled' to :cancelled" do
      assert JobStatus.normalize_state("cancelled") == :cancelled
    end

    test "normalizes 'timeout' to :timeout" do
      assert JobStatus.normalize_state("timeout") == :timeout
    end

    test "treats unknown strings as :processing" do
      assert JobStatus.normalize_state("unknown_state") == :processing
      assert JobStatus.normalize_state("weird") == :processing
      assert JobStatus.normalize_state("") == :processing
    end

    test "handles atom inputs" do
      assert JobStatus.normalize_state(:queued) == :queued
      assert JobStatus.normalize_state(:processing) == :processing
      assert JobStatus.normalize_state(:completed) == :completed
    end
  end

  # Helper to build Job structs for testing
  defp build_job(attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      profile: :standard,
      filename: "test.pdf",
      byte_size: 1024,
      tenant_id: nil,
      user_id: nil,
      submitted_at: DateTime.utc_now(),
      timeout_at: DateTime.add(DateTime.utc_now(), 900_000, :millisecond),
      code_version: :v2,
      metadata: %{},
      backend_used: :docker_cpu,
      backend_endpoint: "http://localhost:8042",
      instance_id: nil,
      state: :queued,
      progress: 0,
      pages_total: nil,
      pages_done: 0,
      last_error: nil,
      result: nil,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    struct(Job, Map.merge(defaults, attrs))
  end
end
