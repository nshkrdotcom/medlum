defmodule Lumainus.Conversion.Backends.LocalBackendTest do
  use Lumainus.Conversion.TestCase

  alias Lumainus.Conversion.Backends.LocalBackend

  @moduletag :capture_log

  describe "backend_type/0" do
    test "returns :local" do
      assert LocalBackend.backend_type() == :local
    end
  end

  describe "name/1" do
    test "returns the configured backend name" do
      # When endpoint is provided in opts, name comes from config
      assert is_atom(LocalBackend.name([]))
    end
  end

  describe "enqueue/2" do
    test "sends multipart request and returns job info" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/jobs", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "job_id" => "test-job-123",
            "state" => "queued"
          })
        )
      end)

      binary = sample_pdf()

      result =
        LocalBackend.enqueue(binary,
          filename: "document.pdf",
          endpoint: bypass_url(bypass)
        )

      assert {:ok, response} = result
      assert response["job_id"] == "test-job-123"
      assert response["state"] == "queued"
    end

    test "returns error on HTTP failure" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/jobs", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s({"error": "Internal Server Error"}))
      end)

      binary = sample_pdf()

      result =
        LocalBackend.enqueue(binary,
          filename: "document.pdf",
          endpoint: bypass_url(bypass)
        )

      assert {:error, {:http_error, 500, _body}} = result
    end

    test "returns transport error on connection failure" do
      # Use a port that's not listening
      result =
        LocalBackend.enqueue(sample_pdf(),
          filename: "document.pdf",
          endpoint: "http://localhost:59999"
        )

      assert {:error, {:transport_error, _reason}} = result
    end
  end

  describe "status/2" do
    test "returns job status" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/jobs/test-job-123/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({
          "job_id": "test-job-123",
          "state": "processing",
          "progress": 50
        }))
      end)

      result = LocalBackend.status("test-job-123", endpoint: bypass_url(bypass))

      assert {:ok, status} = result
      assert status["job_id"] == "test-job-123"
      assert status["state"] == "processing"
      assert status["progress"] == 50
    end

    test "returns error for non-existent job" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/jobs/nonexistent/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, ~s({"error": "Job not found"}))
      end)

      result = LocalBackend.status("nonexistent", endpoint: bypass_url(bypass))

      assert {:error, {:http_error, 404, _body}} = result
    end
  end

  describe "health/1" do
    test "returns healthy status" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": "ok", "version": "1.0.0"}))
      end)

      result = LocalBackend.health(endpoint: bypass_url(bypass))

      assert {:ok, health} = result
      assert health["status"] == "ok"
    end

    test "returns error when unhealthy" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, ~s({"status": "unhealthy"}))
      end)

      result = LocalBackend.health(endpoint: bypass_url(bypass))

      assert {:error, {:http_error, 503, _body}} = result
    end
  end

  describe "cancel/2" do
    test "successfully cancels a job" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "DELETE", "/jobs/test-job-123", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"status": "cancelled"}))
      end)

      result = LocalBackend.cancel("test-job-123", endpoint: bypass_url(bypass))

      assert result == :ok
    end

    test "returns not_found for missing job" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "DELETE", "/jobs/nonexistent", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, ~s({"error": "Job not found"}))
      end)

      result = LocalBackend.cancel("nonexistent", endpoint: bypass_url(bypass))

      assert result == {:error, :not_found}
    end
  end

  describe "await/2" do
    test "awaits job completion with progress callbacks" do
      bypass = Bypass.open()

      # Track progress callback calls
      progress_calls = :ets.new(:progress, [:set, :public])
      :ets.insert(progress_calls, {:calls, []})

      # Return processing, then completed
      call_count = :counters.new(1, [:atomics])

      Bypass.stub(bypass, "GET", "/jobs/test-job-123/status", fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        response =
          if count >= 2 do
            ~s({"job_id": "test-job-123", "state": "completed", "progress": 100, "result": {"markdown": "# Test"}})
          else
            ~s({"job_id": "test-job-123", "state": "processing", "progress": 50})
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response)
      end)

      job_ref = %{
        job_id: "test-job-123",
        timeout_ms: 5000,
        metadata: %{endpoint: bypass_url(bypass)}
      }

      on_status = fn status ->
        [{:calls, calls}] = :ets.lookup(progress_calls, :calls)
        :ets.insert(progress_calls, {:calls, [status | calls]})
      end

      result =
        LocalBackend.await(job_ref,
          timeout_ms: 5000,
          on_status: on_status,
          poll_interval_ms: 50,
          endpoint: bypass_url(bypass)
        )

      assert {:ok, response} = result
      assert response["state"] == "completed"

      # Verify callbacks were called
      [{:calls, calls}] = :ets.lookup(progress_calls, :calls)
      assert length(calls) >= 1

      :ets.delete(progress_calls)
    end

    test "returns error on job failure" do
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/jobs/test-job-123/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({
          "job_id": "test-job-123",
          "state": "failed",
          "error": "Conversion failed"
        }))
      end)

      job_ref = %{
        job_id: "test-job-123",
        timeout_ms: 5000,
        metadata: %{endpoint: bypass_url(bypass)}
      }

      result =
        LocalBackend.await(job_ref,
          timeout_ms: 5000,
          poll_interval_ms: 50,
          endpoint: bypass_url(bypass)
        )

      assert {:error, {:job_failed, _status}} = result
    end
  end
end
