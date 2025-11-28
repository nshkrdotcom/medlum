defmodule Lumainus.Conversion.Backends.CloudBackendTest do
  use Lumainus.Conversion.TestCase

  alias Lumainus.Conversion.Backends.CloudBackend

  @moduletag :capture_log

  describe "backend_type/0" do
    test "returns :cloud" do
      assert CloudBackend.backend_type() == :cloud
    end
  end

  describe "name/0" do
    test "returns :cloud" do
      assert CloudBackend.name() == :cloud
    end
  end

  describe "enqueue/2" do
    test "calls ensure_instance and enqueues when instance is running" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/jobs", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "job_id" => "cloud-job-123",
            "state" => "queued"
          })
        )
      end)

      # Mock CloudStatus to return ready with endpoint
      mock_cloud_status = fn ->
        %{
          availability: :ready,
          endpoint: bypass_url(bypass),
          can_accept_jobs: true,
          message: "Cloud GPU ready"
        }
      end

      binary = sample_pdf()

      result =
        CloudBackend.enqueue(binary,
          filename: "document.pdf",
          cloud_status_fn: mock_cloud_status
        )

      assert {:ok, response} = result
      assert response["job_id"] == "cloud-job-123"
    end

    test "triggers provisioning when cloud available but no instance" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/jobs", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"job_id" => "cloud-job-456", "state" => "queued"}))
      end)

      # First call returns available (triggers provisioning), second returns ready
      call_count = :counters.new(1, [:atomics])

      mock_cloud_status = fn ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          %{availability: :available, endpoint: nil, can_accept_jobs: true, message: "Available"}
        else
          %{
            availability: :ready,
            endpoint: bypass_url(bypass),
            can_accept_jobs: true,
            message: "Ready"
          }
        end
      end

      mock_ensure = fn -> {:ok, bypass_url(bypass)} end

      binary = sample_pdf()

      result =
        CloudBackend.enqueue(binary,
          filename: "document.pdf",
          cloud_status_fn: mock_cloud_status,
          ensure_instance_fn: mock_ensure,
          poll_interval_ms: 10
        )

      assert {:ok, response} = result
      assert response["job_id"] == "cloud-job-456"
    end

    test "returns error when cloud unavailable" do
      mock_cloud_status = fn ->
        %{
          availability: :unavailable,
          endpoint: nil,
          can_accept_jobs: false,
          message: "Cloud GPU not configured"
        }
      end

      binary = sample_pdf()

      result =
        CloudBackend.enqueue(binary,
          filename: "document.pdf",
          cloud_status_fn: mock_cloud_status
        )

      assert {:error, {:cloud_unavailable, "Cloud GPU not configured"}} = result
    end
  end

  describe "status/2" do
    test "returns job status when instance is available" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/jobs/cloud-job-123/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "job_id" => "cloud-job-123",
            "state" => "processing",
            "progress" => 75
          })
        )
      end)

      mock_get_endpoint = fn -> {:ok, bypass_url(bypass)} end

      result =
        CloudBackend.status("cloud-job-123",
          get_endpoint_fn: mock_get_endpoint
        )

      assert {:ok, status} = result
      assert status["state"] == "processing"
    end

    test "returns provisioning when no instance" do
      mock_get_endpoint = fn -> {:error, :no_instance} end

      result =
        CloudBackend.status("cloud-job-123",
          get_endpoint_fn: mock_get_endpoint
        )

      assert {:ok, status} = result
      assert status["state"] == "provisioning"
    end
  end

  describe "health/1" do
    test "returns healthy when instance is running" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"status" => "ok"}))
      end)

      mock_get_endpoint = fn -> {:ok, bypass_url(bypass)} end

      result = CloudBackend.health(get_endpoint_fn: mock_get_endpoint)

      assert {:ok, health} = result
      assert health["status"] == "ok"
    end

    test "returns provisioning status when instance is loading" do
      mock_get_endpoint = fn -> {:error, :no_instance} end
      mock_status = fn -> :loading end

      result =
        CloudBackend.health(
          get_endpoint_fn: mock_get_endpoint,
          instance_status_fn: mock_status
        )

      assert {:ok, status} = result
      assert status["status"] == "provisioning"
    end

    test "returns error when no instance and not loading" do
      mock_get_endpoint = fn -> {:error, :no_instance} end
      mock_status = fn -> :none end

      result =
        CloudBackend.health(
          get_endpoint_fn: mock_get_endpoint,
          instance_status_fn: mock_status
        )

      assert result == {:error, :no_instance}
    end
  end

  describe "cancel/2" do
    test "cancels job when instance available" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "DELETE", "/jobs/cloud-job-123", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"status" => "cancelled"}))
      end)

      mock_get_endpoint = fn -> {:ok, bypass_url(bypass)} end

      result =
        CloudBackend.cancel("cloud-job-123",
          get_endpoint_fn: mock_get_endpoint
        )

      assert result == :ok
    end

    test "returns error when no instance" do
      mock_get_endpoint = fn -> {:error, :no_instance} end

      result =
        CloudBackend.cancel("cloud-job-123",
          get_endpoint_fn: mock_get_endpoint
        )

      assert result == {:error, :no_instance}
    end
  end

  describe "await/2" do
    test "awaits job completion" do
      bypass = Bypass.open()

      call_count = :counters.new(1, [:atomics])

      Bypass.stub(bypass, "GET", "/jobs/cloud-job-123/status", fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        response =
          if count >= 2 do
            Jason.encode!(%{
              "job_id" => "cloud-job-123",
              "state" => "completed",
              "progress" => 100,
              "result" => %{"markdown" => "# Cloud Result"}
            })
          else
            Jason.encode!(%{
              "job_id" => "cloud-job-123",
              "state" => "processing",
              "progress" => 50
            })
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response)
      end)

      job_ref = %{
        job_id: "cloud-job-123",
        timeout_ms: 5000,
        metadata: %{endpoint: bypass_url(bypass)}
      }

      # Mock CloudStatus to return ready with endpoint
      mock_cloud_status = fn ->
        %{
          availability: :ready,
          endpoint: bypass_url(bypass),
          can_accept_jobs: true,
          message: "Cloud GPU ready"
        }
      end

      mock_update_activity = fn -> :ok end

      result =
        CloudBackend.await(job_ref,
          timeout_ms: 5000,
          poll_interval_ms: 50,
          cloud_status_fn: mock_cloud_status,
          update_activity_fn: mock_update_activity
        )

      assert {:ok, response} = result
      assert response["state"] == "completed"
    end

    test "returns error when cloud unavailable" do
      job_ref = %{job_id: "cloud-job-123", timeout_ms: 5000, metadata: %{}}

      mock_cloud_status = fn ->
        %{
          availability: :unavailable,
          endpoint: nil,
          can_accept_jobs: false,
          message: "Cloud GPU not configured"
        }
      end

      result =
        CloudBackend.await(job_ref,
          timeout_ms: 1000,
          cloud_status_fn: mock_cloud_status
        )

      assert {:error, {:cloud_unavailable, "Cloud GPU not configured"}} = result
    end
  end
end
