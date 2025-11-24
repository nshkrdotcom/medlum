defmodule Lumainus.Docling.HTTPTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for Lumainus.Docling.HTTP module.

  Uses Bypass to mock the Docling service endpoints.
  """

  @moduletag :capture_log

  alias Lumainus.Docling.HTTP

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"
    {:ok, bypass: bypass, base_url: base_url}
  end

  describe "convert/3" do
    test "successfully converts PDF binary", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/convert", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert String.contains?(body, "test.pdf")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "markdown" => "# Test Document\n\nSome content.",
            "metadata" => %{"page_count" => 1}
          })
        )
      end)

      pdf_binary = "%PDF-1.4 test content"
      opts = [filename: "test.pdf", content_type: "application/pdf"]

      assert {:ok, result} = HTTP.convert(pdf_binary, opts, base_url: base_url)
      assert result["markdown"] == "# Test Document\n\nSome content."
      assert result["metadata"]["page_count"] == 1
    end

    test "handles timeout option", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/convert", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"markdown" => "test"}))
      end)

      pdf_binary = "%PDF-1.4 test"
      opts = [filename: "test.pdf", timeout_ms: 5_000]

      assert {:ok, _result} = HTTP.convert(pdf_binary, opts, base_url: base_url)
    end

    test "returns error on HTTP 500", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/convert", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "Internal error"}))
      end)

      pdf_binary = "%PDF-1.4 test"
      opts = [filename: "test.pdf"]

      assert {:error, {:http_error, 500, %{"error" => "Internal error"}}} =
               HTTP.convert(pdf_binary, opts, base_url: base_url)
    end

    test "returns error on connection refused", %{base_url: _base_url} do
      # Use a port that's not listening
      bad_url = "http://localhost:59999"
      pdf_binary = "%PDF-1.4 test"
      opts = [filename: "test.pdf", timeout_ms: 1_000]

      assert {:error, _reason} = HTTP.convert(pdf_binary, opts, base_url: bad_url)
    end

    test "includes job_id in request when provided", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/convert", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert String.contains?(body, "my-job-id")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"markdown" => "test"}))
      end)

      pdf_binary = "%PDF-1.4 test"
      opts = [filename: "test.pdf", job_id: "my-job-id"]

      assert {:ok, _result} = HTTP.convert(pdf_binary, opts, base_url: base_url)
    end
  end

  describe "enqueue/3" do
    test "successfully enqueues job", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/jobs", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert String.contains?(body, "test.pdf")
        assert String.contains?(body, "wait")
        assert String.contains?(body, "false")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "job_id" => "job-123",
            "state" => "queued"
          })
        )
      end)

      pdf_binary = "%PDF-1.4 test content"
      opts = [filename: "test.pdf"]

      assert {:ok, result} = HTTP.enqueue(pdf_binary, opts, base_url: base_url)
      assert result["job_id"] == "job-123"
      assert result["state"] == "queued"
    end

    test "returns error on HTTP 400", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/jobs", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"error" => "Invalid file"}))
      end)

      pdf_binary = "not a pdf"
      opts = [filename: "bad.txt"]

      assert {:error, {:http_error, 400, %{"error" => "Invalid file"}}} =
               HTTP.enqueue(pdf_binary, opts, base_url: base_url)
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
            "progress" => 50,
            "pages_done" => 10,
            "pages_total" => 20
          })
        )
      end)

      assert {:ok, result} = HTTP.job_status("job-123", base_url: base_url)
      assert result["state"] == "running"
      assert result["progress"] == 50
    end

    test "returns completed job with result", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/jobs/job-123/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "job_id" => "job-123",
            "state" => "completed",
            "result" => %{"markdown" => "# Done"}
          })
        )
      end)

      assert {:ok, result} = HTTP.job_status("job-123", base_url: base_url)
      assert result["state"] == "completed"
      assert result["result"]["markdown"] == "# Done"
    end

    test "returns error for non-existent job", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/jobs/bad-job/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "Job not found"}))
      end)

      assert {:error, {:http_error, 404, _}} = HTTP.job_status("bad-job", base_url: base_url)
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
            "version" => "2.63.0+lumainus",
            "workers" => 4
          })
        )
      end)

      assert {:ok, result} = HTTP.health(base_url: base_url)
      assert result["status"] == "healthy"
      assert result["version"] == "2.63.0+lumainus"
    end

    test "returns error when service is down", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        Plug.Conn.resp(conn, 503, ~s({"error":"unavailable"}))
      end)

      assert {:error, {:http_error, 503, %{"error" => "unavailable"}}} =
               HTTP.health(base_url: base_url)
    end
  end

  describe "cancel/2" do
    test "successfully cancels job", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "DELETE", "/jobs/job-123", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"status" => "cancelled"}))
      end)

      assert :ok = HTTP.cancel("job-123", base_url: base_url)
    end

    test "returns not_found for non-existent job", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "DELETE", "/jobs/bad-job", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "Job not found"}))
      end)

      assert {:error, :not_found} = HTTP.cancel("bad-job", base_url: base_url)
    end
  end

  describe "build_multipart_fields/3" do
    test "builds correct multipart fields" do
      binary = "test content"

      opts = [
        filename: "test.pdf",
        content_type: "application/pdf",
        byte_size: 12,
        job_id: "job-123"
      ]

      fields = HTTP.build_multipart_fields(binary, opts, output_markdown: true, wait: false)

      assert {:job_id, "job-123"} in fields
      assert {:output_markdown, "true"} in fields
      assert {:wait, "false"} in fields

      file_field =
        Enum.find(fields, fn
          {:file, _} -> true
          _ -> false
        end)

      assert {:file, {^binary, file_opts}} = file_field
      assert file_opts[:filename] == "test.pdf"
      assert file_opts[:content_type] == "application/pdf"
      assert file_opts[:size] == 12
    end

    test "omits job_id when not provided" do
      binary = "test"
      opts = [filename: "test.pdf"]

      fields = HTTP.build_multipart_fields(binary, opts, output_markdown: true)

      refute Enum.any?(fields, fn
               {:job_id, _} -> true
               _ -> false
             end)
    end
  end

  describe "decode_body/1" do
    test "returns map as-is" do
      body = %{"key" => "value"}
      assert HTTP.decode_body(body) == body
    end

    test "decodes JSON string" do
      body = ~s({"key": "value"})
      assert HTTP.decode_body(body) == %{"key" => "value"}
    end

    test "wraps invalid JSON in raw key" do
      body = "not json"
      assert HTTP.decode_body(body) == %{"raw" => "not json"}
    end
  end
end
