defmodule Lumainus.Conversion.ServiceTest do
  use Lumainus.DataCase, async: false

  alias Lumainus.Conversion.Events
  alias Lumainus.Conversion.Service
  alias Lumainus.Conversion.Job
  alias Lumainus.Conversion.JobStatus
  alias Lumainus.Conversion.Application.JobTracker
  alias Lumainus.Repo

  import Lumainus.Conversion.Support.TestHelpers

  defmodule SubmitEventBackend do
    @behaviour Lumainus.Conversion.Backend

    def set_test_pid(pid), do: :persistent_term.put({__MODULE__, :test_pid}, pid)
    def clear!, do: :persistent_term.erase({__MODULE__, :test_pid})

    @impl true
    def enqueue(_binary, opts) do
      caller = self()
      pid = :persistent_term.get({__MODULE__, :test_pid})
      send(pid, {:enqueue_called, opts, caller})

      receive do
        {:continue_enqueue, response} -> response
      after
        1_000 -> {:error, :timeout}
      end
    end

    @impl true
    def await(job_ref, _opts), do: {:ok, %{"job_id" => job_ref[:job_id]}}

    @impl true
    def status(_job_id), do: {:ok, %{"state" => "queued"}}

    @impl true
    def cancel(_job_id), do: :ok

    @impl true
    def health, do: {:ok, %{"status" => "healthy"}}

    @impl true
    def name, do: :docker_cpu

    @impl true
    def backend_type, do: :local
  end

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

  describe "event broadcasting" do
    test "submit broadcasts :submitted event", %{tracker: tracker} do
      SubmitEventBackend.set_test_pid(self())

      backend_router = fn _profile ->
        {:ok,
         %{
           name: :docker_cpu,
           module: SubmitEventBackend,
           endpoint: "http://localhost",
           backend_type: :local
         }}
      end

      task =
        Task.async(fn ->
          Service.submit(sample_pdf(),
            filename: "event.pdf",
            job_tracker: tracker,
            backend_router_fn: backend_router
          )
        end)

      assert_receive {:enqueue_called, opts, caller}
      job_id = Keyword.fetch!(opts, :job_id)

      Events.subscribe(job_id)
      send(caller, {:continue_enqueue, {:ok, %{"job_id" => job_id, "state" => "queued"}}})

      assert {:ok, job} = Task.await(task, 1_000)
      assert job.id == job_id
      assert_receive {:conversion_job, :submitted, %{id: ^job_id}}
    after
      SubmitEventBackend.clear!()
    end

    test "await broadcasts progress and completion", %{tracker: tracker} do
      bypass = Bypass.open()
      {:ok, status_state} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/jobs"} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{"job_id" => "backend-job", "state" => "queued"})
            )

          {"GET", path} ->
            if String.contains?(path, "/jobs/") and String.ends_with?(path, "/status") do
              step = Agent.get_and_update(status_state, fn count -> {count, count + 1} end)

              status =
                case step do
                  0 ->
                    %{
                      "state" => "processing",
                      "progress" => 30,
                      "pages_done" => 1,
                      "pages_total" => 3
                    }

                  1 ->
                    %{
                      "state" => "processing",
                      "progress" => 80,
                      "pages_done" => 3,
                      "pages_total" => 3
                    }

                  _ ->
                    %{"state" => "completed", "progress" => 100, "markdown" => "# done"}
                end

              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.resp(200, Jason.encode!(status))
            else
              Plug.Conn.resp(conn, 404, "not found")
            end
        end
      end)

      backend_router = fn _profile ->
        {:ok,
         %{
           name: :docker_cpu,
           module: Lumainus.Conversion.Backends.LocalBackend,
           endpoint: bypass_url(bypass),
           backend_type: :local
         }}
      end

      {:ok, job} =
        Service.submit(sample_pdf(),
          filename: "await.pdf",
          job_tracker: tracker,
          backend_router_fn: backend_router
        )

      job_id = job.id
      Events.subscribe(job_id)

      assert {:ok, _result} =
               Service.await(job_id,
                 job_tracker: tracker,
                 on_progress: fn _ -> :ok end
               )

      assert_receive {:conversion_job, :progress, %{job_id: ^job_id, progress: 30}}
      assert_receive {:conversion_job, :progress, %{job_id: ^job_id, progress: 80}}
      assert_receive {:conversion_job, :completed, %{id: ^job_id}}
    end
  end

  # Helpers

  defp unique_name(base) do
    :"#{base}_#{System.unique_integer([:positive])}"
  end
end
