defmodule Lumainus.Conversion.Infrastructure.HTTP.ClientTest do
  use Lumainus.Conversion.TestCase

  alias Lumainus.Conversion.Infrastructure.HTTP.Client
  alias Lumainus.Conversion.Infrastructure.Context

  @moduletag :capture_log

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"
    {:ok, bypass: bypass, base_url: base_url}
  end

  describe "enqueue/3" do
    test "successfully enqueues a job", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/jobs", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert String.contains?(body, "test.pdf")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"job_id" => "job-123", "state" => "queued"}))
      end)

      binary = "test content"
      opts = [filename: "test.pdf", content_type: "application/pdf"]

      assert {:ok, result} = Client.enqueue(binary, opts, base_url: base_url)
      assert result["job_id"] == "job-123"
      assert result["state"] == "queued"
    end

    test "returns HTTP error on failure", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/jobs", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"error" => "Invalid file"}))
      end)

      binary = "bad content"
      opts = [filename: "bad.txt"]

      assert {:error, {:http_error, 400, %{"error" => "Invalid file"}}} =
               Client.enqueue(binary, opts, base_url: base_url)
    end

    test "returns transport error on connection failure", %{base_url: _base_url} do
      binary = "test"
      opts = [filename: "test.pdf", timeout_ms: 100]

      # Use a port that's not listening
      assert {:error, {:transport_error, _}} =
               Client.enqueue(binary, opts, base_url: "http://localhost:59999")
    end
  end

  describe "job_status/2" do
    test "returns job status", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/jobs/job-123/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "job_id" => "job-123",
            "state" => "running",
            "progress" => 50
          })
        )
      end)

      assert {:ok, result} = Client.job_status("job-123", base_url: base_url)
      assert result["state"] == "running"
      assert result["progress"] == 50
    end

    test "returns error for non-existent job", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/jobs/missing/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "Job not found"}))
      end)

      assert {:error, {:http_error, 404, _}} = Client.job_status("missing", base_url: base_url)
    end
  end

  describe "health/1" do
    test "returns healthy status", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "status" => "healthy",
            "version" => "2.0.0"
          })
        )
      end)

      assert {:ok, result} = Client.health(base_url: base_url)
      assert result["status"] == "healthy"
    end

    test "returns error when unhealthy", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, Jason.encode!(%{"error" => "unavailable"}))
      end)

      assert {:error, {:http_error, 503, _}} = Client.health(base_url: base_url)
    end
  end

  describe "cancel/2" do
    test "successfully cancels job", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "DELETE", "/jobs/job-123", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"status" => "cancelled"}))
      end)

      assert :ok = Client.cancel("job-123", base_url: base_url)
    end

    test "returns not_found for missing job", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "DELETE", "/jobs/missing", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not found"}))
      end)

      assert {:error, :not_found} = Client.cancel("missing", base_url: base_url)
    end
  end

  describe "trace header injection" do
    test "injects trace headers into requests", %{bypass: bypass, base_url: base_url} do
      # Initialize context
      Context.init(
        trace_id: "test-trace-id",
        span_id: "test-span-id",
        job_id: "test-job-id"
      )

      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        # Check for trace headers
        trace_id = Plug.Conn.get_req_header(conn, "x-trace-id")
        span_id = Plug.Conn.get_req_header(conn, "x-span-id")
        job_id = Plug.Conn.get_req_header(conn, "x-job-id")

        assert trace_id == ["test-trace-id"]
        assert span_id == ["test-span-id"]
        assert job_id == ["test-job-id"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"status" => "healthy"}))
      end)

      assert {:ok, _} = Client.health(base_url: base_url)
    end
  end
end
