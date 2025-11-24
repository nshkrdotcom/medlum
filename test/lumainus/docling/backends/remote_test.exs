defmodule Lumainus.Docling.Backends.RemoteTest do
  use ExUnit.Case, async: false

  alias Lumainus.Docling.Backends.Remote

  @moduledoc """
  Tests for Lumainus.Docling.Backends.Remote module.

  Uses Bypass to mock the remote Docling service.
  """

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    # Set the remote_url config for tests
    original_config = Application.get_env(:lumainus, :docling, [])
    Application.put_env(:lumainus, :docling, Keyword.put(original_config, :remote_url, base_url))

    on_exit(fn ->
      Application.put_env(:lumainus, :docling, original_config)
    end)

    {:ok, bypass: bypass, base_url: base_url}
  end

  describe "convert/2" do
    test "successfully converts PDF via remote service", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/convert", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "markdown" => "# Remote Result",
            "metadata" => %{"page_count" => 5}
          })
        )
      end)

      pdf_binary = "%PDF-1.4 test"
      opts = [filename: "remote.pdf"]

      assert {:ok, result} = Remote.convert(pdf_binary, opts)
      assert result["markdown"] == "# Remote Result"
      assert result["metadata"]["page_count"] == 5
    end
  end

  describe "enqueue/2" do
    test "successfully enqueues job on remote service", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/jobs", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "job_id" => "remote-job-123",
            "state" => "queued"
          })
        )
      end)

      pdf_binary = "%PDF-1.4 test"
      opts = [filename: "remote.pdf", timeout_ms: 120_000]

      assert {:ok, job} = Remote.enqueue(pdf_binary, opts)
      assert job.job_id == "remote-job-123"
      assert job.timeout_ms == 120_000
      assert job.backend == Remote
    end
  end

  describe "await/2" do
    test "returns result when remote job completes", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/jobs/remote-job/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "job_id" => "remote-job",
            "state" => "completed",
            "result" => %{"markdown" => "# Remote Done"}
          })
        )
      end)

      job = %{
        job_id: "remote-job",
        timeout_ms: 5_000,
        timeout_at: DateTime.add(DateTime.utc_now(), 5, :second),
        backend: Remote,
        metadata: %{}
      }

      assert {:ok, result} = Remote.await(job, poll_interval_ms: 100, prefer_sse: false)
      assert result["markdown"] == "# Remote Done"
    end
  end

  describe "health/0" do
    test "returns health from remote service", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "status" => "healthy",
            "version" => "2.63.0+gpu",
            "device" => "cuda"
          })
        )
      end)

      assert {:ok, result} = Remote.health()
      assert result["status"] == "healthy"
      assert result["device"] == "cuda"
    end
  end

  describe "cancel/1" do
    test "cancels job on remote service", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/jobs/remote-cancel", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"status" => "cancelled"}))
      end)

      assert :ok = Remote.cancel("remote-cancel")
    end
  end

  describe "capabilities/0" do
    test "returns expected capabilities" do
      caps = Remote.capabilities()

      assert :sync in caps
      assert :async in caps
      assert :sse in caps
      assert :cancel in caps
    end
  end

  describe "configuration" do
    test "raises when remote_url not configured" do
      original_config = Application.get_env(:lumainus, :docling, [])
      Application.put_env(:lumainus, :docling, Keyword.delete(original_config, :remote_url))

      on_exit(fn ->
        Application.put_env(:lumainus, :docling, original_config)
      end)

      assert_raise RuntimeError, ~r/remote_url/, fn ->
        Remote.health()
      end
    end
  end
end
