defmodule Medlum.Conversion.Infrastructure.HTTP.SSEStreamErrorTest do
  @moduledoc """
  Tests for SSE error handling: 404, timer cleanup, etc.
  """
  use ExUnit.Case, async: true

  alias Medlum.Conversion.Infrastructure.HTTP.SSEStream

  @moduletag :capture_log

  setup_all do
    case start_supervised({Finch, name: Medlum.Finch}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, endpoint: "http://localhost:#{bypass.port}"}
  end

  describe "404 handling" do
    test "stops immediately on 404", %{bypass: bypass, endpoint: endpoint} do
      Bypass.expect(bypass, "GET", "/jobs/missing-job/stream", fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"error": "not found"}))
      end)

      {:ok, pid} =
        SSEStream.subscribe("missing-job",
          base_url: endpoint,
          caller: self(),
          link?: false,
          heartbeat_timeout_ms: 60_000
        )

      assert_receive {:sse_done, "missing-job", :not_found, _result}, 5_000

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    end

    test "stops on 410 Gone", %{bypass: bypass, endpoint: endpoint} do
      Bypass.expect(bypass, "GET", "/jobs/gone-job/stream", fn conn ->
        Plug.Conn.send_resp(conn, 410, ~s({"error": "gone"}))
      end)

      {:ok, pid} =
        SSEStream.subscribe("gone-job",
          base_url: endpoint,
          caller: self(),
          link?: false,
          heartbeat_timeout_ms: 60_000
        )

      assert_receive {:sse_done, "gone-job", :not_found, _result}, 5_000
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    end

    test "reconnects on 500 errors", %{bypass: bypass, endpoint: endpoint} do
      test_pid = self()

      Bypass.stub(bypass, "GET", "/jobs/flaky-job/stream", fn conn ->
        send(test_pid, :attempt)
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      {:ok, pid} =
        SSEStream.subscribe("flaky-job",
          base_url: endpoint,
          caller: self(),
          link?: false,
          heartbeat_timeout_ms: 60_000
        )

      assert_receive :attempt, 500
      assert_receive :attempt, 2_000

      SSEStream.cancel(pid)
    end
  end

  describe "timer cleanup" do
    test "heartbeat timer cancelled on reconnect", %{bypass: bypass, endpoint: endpoint} do
      test_pid = self()

      handler_id =
        :telemetry.attach(
          "sse-reconnect-timer-test-#{System.unique_integer([:positive])}",
          [:medlum, :conversion, :sse, :reconnecting],
          fn event, _measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, metadata})
          end,
          nil
        )

      Bypass.expect(bypass, "GET", "/jobs/timer-test/stream", fn conn ->
        Plug.Conn.send_resp(conn, 500, "error")
      end)

      {:ok, pid} =
        SSEStream.subscribe("timer-test",
          base_url: endpoint,
          caller: self(),
          link?: false,
          heartbeat_timeout_ms: 100
        )

      assert_receive {:telemetry, [:medlum, :conversion, :sse, :reconnecting], _metadata}, 1_000

      state = :sys.get_state(pid)

      case state.heartbeat_ref do
        nil -> :ok
        ref when is_reference(ref) -> :ok
      end

      SSEStream.cancel(pid)
      :telemetry.detach(handler_id)
    end

    test "await returns :not_found for missing jobs", %{bypass: bypass, endpoint: endpoint} do
      Bypass.expect(bypass, "GET", "/jobs/await-404/stream", fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"error": "not found"}))
      end)

      result =
        SSEStream.await("await-404",
          base_url: endpoint,
          timeout_ms: 5_000
        )

      assert {:error, {:job_not_found, _}} = result
    end
  end

  describe "heartbeat events" do
    test "heartbeat events reset timeout but don't terminate", %{
      bypass: bypass,
      endpoint: endpoint
    } do
      Bypass.expect(bypass, "GET", "/jobs/heartbeat-job/stream", fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} =
          Plug.Conn.chunk(conn, "event: heartbeat\ndata: {\"type\":\"heartbeat\"}\n\n")

        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            "event: completed\ndata: {\"state\":\"completed\",\"result\":{}}\n\n"
          )

        conn
      end)

      result =
        SSEStream.await("heartbeat-job",
          base_url: endpoint,
          timeout_ms: 5_000
        )

      assert {:ok, _} = result
    end
  end
end
