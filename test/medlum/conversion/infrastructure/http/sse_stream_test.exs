defmodule Medlum.Conversion.Infrastructure.HTTP.SSEStreamTest do
  use ExUnit.Case, async: false

  import Supertester.OTPHelpers, only: [wait_for_process_death: 2]

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
    base_url = "http://localhost:#{bypass.port}"
    {:ok, bypass: bypass, base_url: base_url, finch_name: Medlum.Finch}
  end

  describe "subscribe/2" do
    test "connects to SSE endpoint and receives events", %{
      bypass: bypass,
      base_url: base_url,
      finch_name: finch_name
    } do
      test_pid = self()

      Bypass.expect(bypass, "GET", "/jobs/job-123/stream", fn conn ->
        conn = Plug.Conn.put_resp_content_type(conn, "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"state\":\"running\",\"progress\":50}\n\n")
        Process.sleep(10)

        {:ok, conn} =
          Plug.Conn.chunk(conn, "data: {\"state\":\"completed\",\"progress\":100}\n\n")

        conn
      end)

      {:ok, pid} =
        subscribe_unlinked("job-123",
          base_url: base_url,
          finch_name: finch_name,
          on_event: fn event -> send(test_pid, {:got_event, event}) end
        )

      assert_receive {:sse_event, "job-123", %{"state" => "running", "progress" => 50}}, 1000
      assert_receive {:sse_event, "job-123", %{"state" => "completed", "progress" => 100}}, 1000
      assert_receive {:sse_done, "job-123", :completed, _}, 1000

      assert_receive {:got_event, %{"progress" => 50}}, 100
      assert_receive {:got_event, %{"progress" => 100}}, 100

      assert {:ok, reason} = wait_for_process_death(pid, 300)
      assert reason in [:normal, :noproc]
    end

    test "handles failed state", %{bypass: bypass, base_url: base_url, finch_name: finch_name} do
      Bypass.expect(bypass, "GET", "/jobs/job-456/stream", fn conn ->
        conn = Plug.Conn.put_resp_content_type(conn, "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} =
          Plug.Conn.chunk(conn, "data: {\"state\":\"failed\",\"error\":\"Out of memory\"}\n\n")

        conn
      end)

      {:ok, _pid} = subscribe_unlinked("job-456", base_url: base_url, finch_name: finch_name)

      assert_receive {:sse_event, "job-456", %{"state" => "failed"}}, 1000
      assert_receive {:sse_done, "job-456", :failed, _}, 1000
    end

    test "handles cancelled state", %{bypass: bypass, base_url: base_url, finch_name: finch_name} do
      Bypass.expect(bypass, "GET", "/jobs/job-789/stream", fn conn ->
        conn = Plug.Conn.put_resp_content_type(conn, "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"state\":\"cancelled\"}\n\n")
        conn
      end)

      {:ok, _pid} = subscribe_unlinked("job-789", base_url: base_url, finch_name: finch_name)

      assert_receive {:sse_event, "job-789", %{"state" => "cancelled"}}, 1000
      assert_receive {:sse_done, "job-789", :cancelled, _}, 1000
    end
  end

  describe "cancel/1" do
    test "stops the SSE stream process", %{
      bypass: bypass,
      base_url: base_url,
      finch_name: finch_name
    } do
      assert :ok ==
               with_shutdown_tolerated(fn ->
                 Bypass.stub(bypass, "GET", "/jobs/cancel-test/stream", fn conn ->
                   conn = Plug.Conn.put_resp_content_type(conn, "text/event-stream")
                   conn = Plug.Conn.send_chunked(conn, 200)

                   {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"state\":\"running\"}\n\n")
                   Process.sleep(200)
                   conn
                 end)

                 {:ok, pid} =
                   subscribe_unlinked("cancel-test", base_url: base_url, finch_name: finch_name)

                 assert_receive {:sse_event, "cancel-test", _}, 500
                 :ok = SSEStream.cancel(pid)
                 Bypass.pass(bypass)

                 assert {:ok, reason} = wait_for_down(pid, 500)
                 assert reason in [:normal, :shutdown, :noproc]
               end)
    end
  end

  describe "reconnection" do
    test "reconnects on connection failure with backoff", %{
      bypass: bypass,
      base_url: base_url,
      finch_name: finch_name
    } do
      test_pid = self()
      attempt_counter = :counters.new(1, [])

      Bypass.stub(bypass, "GET", "/jobs/reconnect-test/stream", fn conn ->
        :counters.add(attempt_counter, 1, 1)
        attempt = :counters.get(attempt_counter, 1)
        send(test_pid, {:connection_attempt, attempt})

        if attempt < 3 do
          Plug.Conn.resp(conn, 500, "Server error")
        else
          conn = Plug.Conn.put_resp_content_type(conn, "text/event-stream")
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"state\":\"completed\"}\n\n")
          conn
        end
      end)

      {:ok, _pid} =
        subscribe_unlinked("reconnect-test", base_url: base_url, finch_name: finch_name)

      assert_receive {:connection_attempt, 1}, 500
      assert_receive {:connection_attempt, 2}, 2000
      assert_receive {:connection_attempt, 3}, 3000

      assert_receive {:sse_done, "reconnect-test", :completed, _}, 5000
    end

    test "emits telemetry on reconnection", %{
      bypass: bypass,
      base_url: base_url,
      finch_name: finch_name
    } do
      test_pid = self()
      handler_id = attach_sse_reconnecting_handler(test_pid)
      attempt_counter = :counters.new(1, [])

      Bypass.stub(bypass, "GET", "/jobs/telemetry-test/stream", fn conn ->
        :counters.add(attempt_counter, 1, 1)
        attempt = :counters.get(attempt_counter, 1)

        if attempt < 2 do
          Plug.Conn.resp(conn, 503, "Unavailable")
        else
          conn = Plug.Conn.put_resp_content_type(conn, "text/event-stream")
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"state\":\"completed\"}\n\n")
          conn
        end
      end)

      {:ok, _pid} =
        subscribe_unlinked("telemetry-test", base_url: base_url, finch_name: finch_name)

      assert_receive {:telemetry, [:medlum, :conversion, :sse, :reconnecting], _, _}, 3000
      :telemetry.detach(handler_id)
    end
  end

  describe "heartbeat timeout" do
    test "triggers reconnect after heartbeat timeout", %{
      bypass: bypass,
      base_url: base_url,
      finch_name: finch_name
    } do
      assert :ok ==
               with_shutdown_tolerated(fn ->
                 Process.flag(:trap_exit, true)
                 test_pid = self()
                 attempt_counter = :counters.new(1, [])

                 Bypass.stub(bypass, "GET", "/jobs/heartbeat-test/stream", fn conn ->
                   :counters.add(attempt_counter, 1, 1)
                   attempt = :counters.get(attempt_counter, 1)
                   send(test_pid, {:connection_attempt, attempt})

                   conn = Plug.Conn.put_resp_content_type(conn, "text/event-stream")
                   conn = Plug.Conn.send_chunked(conn, 200)

                   if attempt < 2 do
                     Process.sleep(300)
                     conn
                   else
                     {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"state\":\"completed\"}\n\n")
                     conn
                   end
                 end)

                 {:ok, pid} =
                   subscribe_unlinked("heartbeat-test",
                     base_url: base_url,
                     finch_name: finch_name,
                     heartbeat_timeout_ms: 100
                   )

                 assert_receive {:connection_attempt, 1}, 500
                 assert_receive {:connection_attempt, 2}, 3000

                 assert_receive {:sse_done, "heartbeat-test", :completed, _}, 3000
                 SSEStream.cancel(pid)
                 Bypass.pass(bypass)
               end)
    end

    test "emits telemetry on heartbeat timeout", %{
      bypass: bypass,
      base_url: base_url,
      finch_name: finch_name
    } do
      assert :ok ==
               with_shutdown_tolerated(fn ->
                 Process.flag(:trap_exit, true)
                 test_pid = self()
                 handler_id = attach_heartbeat_timeout_handler(test_pid)
                 attempt_counter = :counters.new(1, [])

                 Bypass.stub(bypass, "GET", "/jobs/hb-telemetry/stream", fn conn ->
                   :counters.add(attempt_counter, 1, 1)
                   attempt = :counters.get(attempt_counter, 1)

                   conn = Plug.Conn.put_resp_content_type(conn, "text/event-stream")
                   conn = Plug.Conn.send_chunked(conn, 200)

                   if attempt < 2 do
                     Process.sleep(300)
                     conn
                   else
                     {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"state\":\"completed\"}\n\n")
                     conn
                   end
                 end)

                 {:ok, pid} =
                   subscribe_unlinked("hb-telemetry",
                     base_url: base_url,
                     finch_name: finch_name,
                     heartbeat_timeout_ms: 100
                   )

                 assert_receive {:telemetry, [:medlum, :conversion, :sse, :heartbeat_timeout], _,
                                 _},
                                3000

                 SSEStream.cancel(pid)
                 Bypass.pass(bypass)
                 :telemetry.detach(handler_id)
               end)
    end
  end

  describe "data received resets heartbeat" do
    test "receiving data prevents heartbeat timeout", %{
      bypass: bypass,
      base_url: base_url,
      finch_name: finch_name
    } do
      test_pid = self()

      Bypass.expect(bypass, "GET", "/jobs/active-test/stream", fn conn ->
        conn = Plug.Conn.put_resp_content_type(conn, "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"state\":\"running\",\"progress\":10}\n\n")
        Process.sleep(50)
        {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"state\":\"running\",\"progress\":20}\n\n")
        Process.sleep(50)
        {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"state\":\"running\",\"progress\":30}\n\n")
        Process.sleep(50)

        {:ok, conn} =
          Plug.Conn.chunk(conn, "data: {\"state\":\"completed\",\"progress\":100}\n\n")

        conn
      end)

      handler_id = attach_heartbeat_timeout_handler(test_pid)

      {:ok, _pid} =
        subscribe_unlinked("active-test",
          base_url: base_url,
          finch_name: finch_name,
          heartbeat_timeout_ms: 100
        )

      assert_receive {:sse_event, "active-test", %{"progress" => 10}}, 500
      assert_receive {:sse_event, "active-test", %{"progress" => 20}}, 500
      assert_receive {:sse_event, "active-test", %{"progress" => 30}}, 500
      assert_receive {:sse_done, "active-test", :completed, _}, 500

      refute_receive {:telemetry, [:medlum, :conversion, :sse, :heartbeat_timeout], _, _}, 100

      :telemetry.detach(handler_id)
    end
  end

  describe "SSE event parsing" do
    test "parses JSON data from SSE format", %{
      bypass: bypass,
      base_url: base_url,
      finch_name: finch_name
    } do
      Bypass.expect(bypass, "GET", "/jobs/parse-test/stream", fn conn ->
        conn = Plug.Conn.put_resp_content_type(conn, "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            "data: {\"job_id\":\"parse-test\",\"state\":\"completed\",\"pages\":5}\n\n"
          )

        conn
      end)

      {:ok, _pid} = subscribe_unlinked("parse-test", base_url: base_url, finch_name: finch_name)

      assert_receive {:sse_event, "parse-test", event}, 1000
      assert event["job_id"] == "parse-test"
      assert event["state"] == "completed"
      assert event["pages"] == 5
    end

    test "handles event type field", %{bypass: bypass, base_url: base_url, finch_name: finch_name} do
      Bypass.expect(bypass, "GET", "/jobs/event-type/stream", fn conn ->
        conn = Plug.Conn.put_resp_content_type(conn, "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            "event: progress\ndata: {\"state\":\"running\",\"progress\":50}\n\n"
          )

        Process.sleep(10)

        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            "event: complete\ndata: {\"state\":\"completed\"}\n\n"
          )

        conn
      end)

      {:ok, _pid} = subscribe_unlinked("event-type", base_url: base_url, finch_name: finch_name)

      assert_receive {:sse_event, "event-type", event1}, 1000
      assert event1["progress"] == 50

      assert_receive {:sse_done, "event-type", :completed, _}, 1000
    end

    test "ignores malformed SSE data", %{
      bypass: bypass,
      base_url: base_url,
      finch_name: finch_name
    } do
      Bypass.expect(bypass, "GET", "/jobs/malformed/stream", fn conn ->
        conn = Plug.Conn.put_resp_content_type(conn, "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} = Plug.Conn.chunk(conn, "data: not-valid-json\n\n")
        Process.sleep(10)

        {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"state\":\"completed\"}\n\n")
        conn
      end)

      {:ok, _pid} = subscribe_unlinked("malformed", base_url: base_url, finch_name: finch_name)

      assert_receive {:sse_done, "malformed", :completed, _}, 1000
    end
  end

  describe "telemetry" do
    test "emits connected telemetry", %{
      bypass: bypass,
      base_url: base_url,
      finch_name: finch_name
    } do
      test_pid = self()
      handler_id = attach_sse_connected_handler(test_pid)

      Bypass.expect(bypass, "GET", "/jobs/connected-telemetry/stream", fn conn ->
        send(test_pid, :request_hit)
        conn = Plug.Conn.put_resp_content_type(conn, "text/event-stream")
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"state\":\"completed\"}\n\n")
        conn
      end)

      {:ok, pid} =
        subscribe_unlinked("connected-telemetry", base_url: base_url, finch_name: finch_name)

      assert_receive :request_hit, 1000

      assert_receive {:telemetry, [:medlum, :conversion, :sse, :connected], %{count: 1}, _},
                     1000

      SSEStream.cancel(pid)
      Bypass.pass(bypass)
      :telemetry.detach(handler_id)
    end

    test "emits error telemetry on HTTP error", %{
      bypass: bypass,
      base_url: base_url,
      finch_name: finch_name
    } do
      test_pid = self()
      handler_id = attach_sse_error_handler(test_pid)
      attempt_counter = :counters.new(1, [])

      Bypass.stub(bypass, "GET", "/jobs/error-telemetry/stream", fn conn ->
        :counters.add(attempt_counter, 1, 1)
        attempt = :counters.get(attempt_counter, 1)

        if attempt < 2 do
          Plug.Conn.resp(conn, 500, "Error")
        else
          conn = Plug.Conn.put_resp_content_type(conn, "text/event-stream")
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"state\":\"completed\"}\n\n")
          conn
        end
      end)

      {:ok, _pid} =
        subscribe_unlinked("error-telemetry", base_url: base_url, finch_name: finch_name)

      assert_receive {:telemetry, [:medlum, :conversion, :sse, :error], %{count: 1}, _}, 3000

      :telemetry.detach(handler_id)
    end
  end

  defp subscribe_unlinked(job_id, opts) do
    opts = Keyword.merge([caller: self(), link?: false], opts)
    {:ok, pid} = SSEStream.subscribe(job_id, opts)
    Process.unlink(pid)

    on_exit(fn ->
      try do
        SSEStream.cancel(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, pid}
  end

  defp wait_for_down(pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> {:ok, reason}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  defp attach_sse_connected_handler(test_pid) do
    handler_id = "sse-connected-handler-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:medlum, :conversion, :sse, :connected],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  defp attach_sse_reconnecting_handler(test_pid) do
    handler_id = "sse-reconnecting-handler-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:medlum, :conversion, :sse, :reconnecting],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  defp attach_heartbeat_timeout_handler(test_pid) do
    handler_id = "sse-heartbeat-handler-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:medlum, :conversion, :sse, :heartbeat_timeout],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  defp attach_sse_error_handler(test_pid) do
    handler_id = "sse-error-handler-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:medlum, :conversion, :sse, :error],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  defp with_shutdown_tolerated(fun) when is_function(fun, 0) do
    try do
      fun.()
      :ok
    catch
      :exit, :shutdown -> :ok
      :exit, {:shutdown, _} -> :ok
    end
  end
end
