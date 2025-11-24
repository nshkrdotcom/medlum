defmodule Lumainus.Docling.Backends.LocalTest do
  use ExUnit.Case, async: false

  alias Lumainus.Docling.Backends.Local

  @moduledoc """
  Tests for Lumainus.Docling.Backends.Local module.

  Uses Bypass to mock the local Docling service.
  """

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    # Set the local_url config for tests
    original_config = Application.get_env(:lumainus, :docling, [])
    Application.put_env(:lumainus, :docling, Keyword.put(original_config, :local_url, base_url))

    on_exit(fn ->
      Application.put_env(:lumainus, :docling, original_config)
    end)

    {:ok, bypass: bypass, base_url: base_url}
  end

  describe "convert/2" do
    test "successfully converts PDF", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/convert", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "markdown" => "# Test\n\nContent",
            "metadata" => %{"page_count" => 1}
          })
        )
      end)

      pdf_binary = "%PDF-1.4 test"
      opts = [filename: "test.pdf"]

      assert {:ok, result} = Local.convert(pdf_binary, opts)
      assert result["markdown"] == "# Test\n\nContent"
    end

    test "returns error on failure", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/convert", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "Failed"}))
      end)

      pdf_binary = "%PDF-1.4 test"
      opts = [filename: "test.pdf"]

      assert {:error, {:http_error, 500, _}} = Local.convert(pdf_binary, opts)
    end
  end

  describe "enqueue/2" do
    test "successfully enqueues job and returns job struct", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/jobs", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "job_id" => "job-456",
            "state" => "queued"
          })
        )
      end)

      pdf_binary = "%PDF-1.4 test"
      opts = [filename: "test.pdf", timeout_ms: 60_000]

      assert {:ok, job} = Local.enqueue(pdf_binary, opts)
      assert job.job_id == "job-456"
      assert job.timeout_ms == 60_000
      assert job.backend == Local
      assert %DateTime{} = job.timeout_at
    end
  end

  describe "await/2" do
    test "returns result when job completes", %{bypass: bypass} do
      # First call returns running
      Bypass.expect(bypass, "GET", "/jobs/job-789/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "job_id" => "job-789",
            "state" => "completed",
            "result" => %{"markdown" => "# Done"}
          })
        )
      end)

      job = %{
        job_id: "job-789",
        timeout_ms: 5_000,
        timeout_at: DateTime.add(DateTime.utc_now(), 5, :second),
        backend: Local,
        metadata: %{}
      }

      assert {:ok, result} = Local.await(job, poll_interval_ms: 100)
      assert result["markdown"] == "# Done"
    end

    test "invokes on_status callback", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect(bypass, "GET", "/jobs/job-status/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "job_id" => "job-status",
            "state" => "completed",
            "progress" => 100,
            "result" => %{"markdown" => "done"}
          })
        )
      end)

      job = %{
        job_id: "job-status",
        timeout_ms: 5_000,
        timeout_at: DateTime.add(DateTime.utc_now(), 5, :second),
        backend: Local,
        metadata: %{}
      }

      on_status = fn status ->
        send(test_pid, {:status, status})
        :ok
      end

      {:ok, _result} = Local.await(job, on_status: on_status, poll_interval_ms: 100)

      assert_receive {:status, %{"state" => "completed"}}
    end
  end

  describe "health/0" do
    test "returns healthy status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "status" => "healthy",
            "version" => "2.63.0"
          })
        )
      end)

      assert {:ok, result} = Local.health()
      assert result["status"] == "healthy"
    end
  end

  describe "cancel/1" do
    test "successfully cancels job", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/jobs/job-cancel", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"status" => "cancelled"}))
      end)

      assert :ok = Local.cancel("job-cancel")
    end
  end

  describe "capabilities/0" do
    test "returns expected capabilities" do
      caps = Local.capabilities()

      assert :sync in caps
      assert :async in caps
      assert :sse in caps
      assert :cancel in caps
    end
  end
end
