defmodule Lumainus.Docling.Backends.VastAITest do
  use ExUnit.Case, async: false

  alias Lumainus.Docling.Backends.VastAI
  alias Lumainus.Docling.VastAI.InstanceManager

  @moduledoc """
  Tests for Lumainus.Docling.Backends.VastAI module.

  Uses Bypass to mock the Docling service on the provisioned instance.
  """

  setup do
    bypass = Bypass.open()
    endpoint = "http://localhost:#{bypass.port}"

    # Start InstanceManager
    start_supervised!(InstanceManager)

    # Set up config with mock provisioner
    original_config = Application.get_env(:lumainus, :docling, [])

    mock_provision = fn -> {:ok, "test-instance", endpoint} end
    mock_destroy = fn _id -> :ok end

    new_config =
      Keyword.put(original_config, :vast_ai,
        provisioner: mock_provision,
        destroyer: mock_destroy,
        api_key: "test-key"
      )

    Application.put_env(:lumainus, :docling, new_config)

    on_exit(fn ->
      Application.put_env(:lumainus, :docling, original_config)
    end)

    {:ok, bypass: bypass, endpoint: endpoint}
  end

  describe "convert/2" do
    test "provisions instance and converts PDF", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/convert", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "markdown" => "# VastAI Result",
            "metadata" => %{"device" => "cuda"}
          })
        )
      end)

      pdf_binary = "%PDF-1.4 test"
      opts = [filename: "gpu.pdf"]

      assert {:ok, result} = VastAI.convert(pdf_binary, opts)
      assert result["markdown"] == "# VastAI Result"
      assert result["metadata"]["device"] == "cuda"
    end
  end

  describe "enqueue/2" do
    test "provisions instance and enqueues job", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/jobs", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "job_id" => "vast-job-123",
            "state" => "queued"
          })
        )
      end)

      pdf_binary = "%PDF-1.4 test"
      opts = [filename: "gpu.pdf", timeout_ms: 300_000]

      assert {:ok, job} = VastAI.enqueue(pdf_binary, opts)
      assert job.job_id == "vast-job-123"
      assert job.timeout_ms == 300_000
      assert job.backend == VastAI
      assert is_binary(job.metadata.endpoint)
    end
  end

  describe "await/2" do
    test "returns result when job completes", %{bypass: bypass, endpoint: endpoint} do
      Bypass.expect(bypass, "GET", "/jobs/vast-job/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "job_id" => "vast-job",
            "state" => "completed",
            "result" => %{"markdown" => "# GPU Done"}
          })
        )
      end)

      job = %{
        job_id: "vast-job",
        timeout_ms: 5_000,
        timeout_at: DateTime.add(DateTime.utc_now(), 5, :second),
        backend: VastAI,
        metadata: %{endpoint: endpoint}
      }

      assert {:ok, result} = VastAI.await(job, poll_interval_ms: 100)
      assert result["markdown"] == "# GPU Done"
    end
  end

  describe "health/0" do
    test "returns health from provisioned instance", %{bypass: bypass} do
      # First need to ensure instance exists
      Bypass.expect(bypass, "GET", "/health", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "status" => "healthy",
            "device" => "cuda:0"
          })
        )
      end)

      # Trigger instance provisioning
      {:ok, _} = InstanceManager.ensure_instance()

      assert {:ok, result} = VastAI.health()
      assert result["status"] == "healthy"
      assert result["device"] == "cuda:0"
    end

    test "returns no_instance status when not provisioned" do
      # Destroy any existing instance
      InstanceManager.destroy_instance()

      assert {:ok, result} = VastAI.health()
      assert result["status"] == "no_instance"
    end
  end

  describe "cancel/1" do
    test "cancels job on provisioned instance", %{bypass: bypass} do
      # Ensure instance exists
      {:ok, _} = InstanceManager.ensure_instance()

      Bypass.expect_once(bypass, "DELETE", "/jobs/vast-cancel", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"status" => "cancelled"}))
      end)

      assert :ok = VastAI.cancel("vast-cancel")
    end

    test "returns error when no instance exists" do
      InstanceManager.destroy_instance()

      assert {:error, :no_instance} = VastAI.cancel("job-id")
    end
  end

  describe "capabilities/0" do
    test "returns GPU and auto_provision capabilities" do
      caps = VastAI.capabilities()

      assert :sync in caps
      assert :async in caps
      assert :gpu in caps
      assert :auto_provision in caps
    end
  end
end
