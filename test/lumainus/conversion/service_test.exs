defmodule Lumainus.Conversion.ServiceTest do
  use Lumainus.DataCase, async: false

  alias Lumainus.Conversion.Service
  alias Lumainus.Conversion.Job
  alias Lumainus.Conversion.JobStatus
  alias Lumainus.Conversion.Application.JobTracker
  alias Lumainus.Repo

  import Lumainus.Conversion.Support.TestHelpers

  @moduletag :capture_log

  setup do
    # Clean up any existing data
    Repo.delete_all(Job)

    # Start JobTracker for tests
    tracker_name = unique_name(:tracker)
    table_name = unique_name(:ets)

    {:ok, _} = start_supervised({JobTracker, name: tracker_name, table_name: table_name})

    %{tracker: tracker_name, table: table_name}
  end

  describe "submit/2" do
    test "validates file and rejects too large", %{tracker: tracker} do
      # Create a file over 100MB
      large_binary = :binary.copy(<<0>>, 100 * 1024 * 1024 + 1)

      result =
        Service.submit(large_binary,
          filename: "large.pdf",
          job_tracker: tracker
        )

      assert result == {:error, :file_too_large}
    end

    test "validates content type and rejects non-PDF", %{tracker: tracker} do
      result =
        Service.submit(sample_pdf(),
          filename: "document.docx",
          content_type: "application/msword",
          job_tracker: tracker
        )

      assert result == {:error, :invalid_content_type}
    end

    test "routes to backend and persists job with provenance", %{tracker: tracker} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/jobs", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "job_id" => "backend-job-123",
            "state" => "queued"
          })
        )
      end)

      # Mock the router to return our test backend (using valid enum value)
      mock_router = fn _profile ->
        {:ok,
         %{
           name: :docker_cpu,
           module: Lumainus.Conversion.Backends.LocalBackend,
           endpoint: bypass_url(bypass),
           backend_type: :local
         }}
      end

      result =
        Service.submit(sample_pdf(),
          filename: "test.pdf",
          profile: :standard,
          job_tracker: tracker,
          backend_router_fn: mock_router
        )

      assert {:ok, job} = result
      assert job.profile == :standard
      assert job.filename == "test.pdf"
      assert job.backend_used == :docker_cpu
      assert job.backend_endpoint == bypass_url(bypass)
    end

    test "does NOT retry on enqueue failure", %{tracker: tracker} do
      bypass = Bypass.open()

      # Track call count
      call_count = :counters.new(1, [:atomics])

      Bypass.stub(bypass, "POST", "/jobs", fn conn ->
        :counters.add(call_count, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "Server error"}))
      end)

      mock_router = fn _profile ->
        {:ok,
         %{
           name: :docker_cpu,
           module: Lumainus.Conversion.Backends.LocalBackend,
           endpoint: bypass_url(bypass),
           backend_type: :local
         }}
      end

      result =
        Service.submit(sample_pdf(),
          filename: "test.pdf",
          job_tracker: tracker,
          backend_router_fn: mock_router
        )

      # Should fail
      assert {:error, _} = result

      # Should only have been called ONCE (no retries)
      assert :counters.get(call_count, 1) == 1
    end

    test "returns service_unavailable when no backends available", %{tracker: tracker} do
      mock_router = fn _profile -> {:error, :service_unavailable} end

      result =
        Service.submit(sample_pdf(),
          filename: "test.pdf",
          job_tracker: tracker,
          backend_router_fn: mock_router
        )

      assert result == {:error, :service_unavailable}
    end
  end

  describe "status/1" do
    test "returns JobStatus with provenance", %{tracker: tracker} do
      # Create a job directly
      changeset =
        Job.new(%{
          profile: :standard,
          filename: "status_test.pdf",
          byte_size: 1024
        })
        |> Ecto.Changeset.put_change(:backend_used, :docker_cpu)
        |> Ecto.Changeset.put_change(:backend_endpoint, "http://localhost:8042")
        |> Ecto.Changeset.put_change(:state, :processing)
        |> Ecto.Changeset.put_change(:progress, 50)

      {:ok, job} = JobTracker.register(tracker, changeset)

      result = Service.status(job.id, job_tracker: tracker)

      assert {:ok, status} = result
      assert %JobStatus{} = status
      assert status.job_id == job.id
      assert status.state == :processing
      assert status.progress == 50
      assert status.backend_used == :docker_cpu
      assert status.backend_endpoint == "http://localhost:8042"
    end

    test "returns error for non-existent job", %{tracker: tracker} do
      fake_id = Ecto.UUID.generate()

      result = Service.status(fake_id, job_tracker: tracker)

      assert result == {:error, :not_found}
    end
  end

  describe "cancel/1" do
    test "updates job state to cancelled", %{tracker: tracker} do
      bypass = Bypass.open()

      # Create a job first so we know the ID
      changeset =
        Job.new(%{
          profile: :standard,
          filename: "cancel_test.pdf",
          byte_size: 1024
        })
        |> Ecto.Changeset.put_change(:backend_used, :docker_cpu)
        |> Ecto.Changeset.put_change(:backend_endpoint, bypass_url(bypass))
        |> Ecto.Changeset.put_change(:state, :processing)

      {:ok, job} = JobTracker.register(tracker, changeset)

      # Now set up Bypass with the known job ID
      Bypass.expect_once(bypass, "DELETE", "/jobs/#{job.id}", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"status": "cancelled"}))
      end)

      result = Service.cancel(job.id, job_tracker: tracker)

      assert result == :ok

      # Verify state updated
      {:ok, updated_job} = JobTracker.get(tracker, job.id)
      assert updated_job.state == :cancelled
    end
  end

  describe "available?/1" do
    test "returns true when backend is available" do
      mock_router = fn _profile ->
        {:ok, %{name: :test, module: nil, endpoint: nil, backend_type: :local}}
      end

      result = Service.available?(:standard, backend_router_fn: mock_router)

      assert result == true
    end

    test "returns false when no backends available" do
      mock_router = fn _profile -> {:error, :service_unavailable} end

      result = Service.available?(:standard, backend_router_fn: mock_router)

      assert result == false
    end
  end

  describe "profiles/1" do
    test "returns list of available profiles" do
      # Mock router that makes :standard available but not :enhanced
      mock_router = fn
        :standard -> {:ok, %{name: :docker_cpu, module: nil, endpoint: nil, backend_type: :local}}
        :enhanced -> {:error, :service_unavailable}
      end

      profiles = Service.profiles(backend_router_fn: mock_router)

      assert is_list(profiles)
      assert :standard in profiles
      refute :enhanced in profiles
    end
  end

  # Helpers

  defp unique_name(base) do
    :"#{base}_#{System.unique_integer([:positive])}"
  end
end
