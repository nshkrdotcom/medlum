defmodule Lumainus.Conversion.Infrastructure.HTTP.SSEStream do
  @moduledoc """
  Server-Sent Events client with automatic reconnection.

  ## Features
  - Exponential backoff reconnection: [1s, 2s, 5s, 10s, 30s]
  - Heartbeat monitoring (configurable, default 60s timeout)
  - JSON event parsing
  - Terminal state detection (completed/failed/cancelled)

  ## Usage

      {:ok, pid} = SSEStream.subscribe(job_id,
        base_url: "http://localhost:8042",
        timeout_ms: 300_000,
        on_event: fn event -> handle(event) end
      )

  Events are sent to the caller process as:
  - `{:sse_event, job_id, event_map}` - Progress and status updates
  - `{:sse_done, job_id, :completed | :failed | :cancelled}` - Terminal state

  ## Options

  - `:base_url` - Required. Base URL for the SSE endpoint
  - `:timeout_ms` - Overall timeout (default: 300_000)
  - `:finch_name` - Finch instance to use (default: `Lumainus.Finch`)
  - `:caller` - Process that receives SSE events (default: the caller)
  - `:on_event` - Callback function for each event
  - `:heartbeat_timeout_ms` - Heartbeat timeout (default: 60_000)
  - `:link?` - When false, starts the process without linking to the caller (test hook)
  """

  use GenServer
  require Logger

  alias Lumainus.Conversion.Infrastructure.Telemetry.Emitter

  @reconnect_delays [1_000, 2_000, 5_000, 10_000, 30_000]
  @default_heartbeat_timeout_ms 60_000

  defstruct [
    :job_id,
    :base_url,
    :timeout_ms,
    :finch_name,
    :on_event,
    :caller,
    :link?,
    :task_pid,
    :reconnect_index,
    :heartbeat_ref,
    :heartbeat_timeout_ms,
    :buffer
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Subscribe to SSE stream for a job.

  Returns `{:ok, pid}` on success. The pid can be used with `cancel/1`.
  """
  @spec subscribe(String.t(), keyword()) :: {:ok, pid()}
  def subscribe(job_id, opts) do
    caller = Keyword.get(opts, :caller, self())

    start_fun =
      if Keyword.get(opts, :link?, true) do
        &GenServer.start_link/3
      else
        &GenServer.start/3
      end

    start_fun.(__MODULE__, {job_id, opts, caller}, [])
  end

  @doc """
  Cancel an SSE stream subscription.
  """
  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, :noproc -> :ok
        :exit, {:noproc, _} -> :ok
      end
    end

    :ok
  end

  def cancel(_), do: :ok

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init({job_id, opts, caller}) do
    link? = Keyword.get(opts, :link?, true)

    # Ensure tests can run without propagating exits when link?: false
    if link? == false do
      Process.unlink(caller)
      Process.flag(:trap_exit, true)
    end

    heartbeat_timeout =
      Keyword.get(
        opts,
        :heartbeat_timeout_ms,
        Application.get_env(:lumainus, :sse_heartbeat_timeout_ms, @default_heartbeat_timeout_ms)
      )

    state = %__MODULE__{
      job_id: job_id,
      base_url: Keyword.fetch!(opts, :base_url),
      timeout_ms: Keyword.get(opts, :timeout_ms, 300_000),
      finch_name: Keyword.get(opts, :finch_name, Lumainus.Finch),
      on_event: Keyword.get(opts, :on_event, fn _ -> :ok end),
      caller: caller,
      link?: link?,
      reconnect_index: 0,
      heartbeat_timeout_ms: heartbeat_timeout,
      buffer: ""
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    url = "#{state.base_url}/jobs/#{state.job_id}/events"

    case start_sse_connection(url, state.timeout_ms, state.finch_name) do
      {:ok, task_pid} ->
        Logger.debug("[SSEStream] Connected to #{url}")
        Emitter.emit_sse_connected(state.job_id)
        heartbeat_ref = schedule_heartbeat_check(state.heartbeat_timeout_ms)

        {:noreply,
         %{
           state
           | task_pid: task_pid,
             reconnect_index: 0,
             heartbeat_ref: heartbeat_ref,
             buffer: ""
         }}

      {:error, reason} ->
        Logger.warning("[SSEStream] Connection failed: #{inspect(reason)}")
        Emitter.emit_sse_error(state.job_id, reason)
        schedule_reconnect(state)
    end
  end

  @impl true
  def handle_info({:sse_status, status}, state) when status in 200..299 do
    # Good status, connection established
    {:noreply, state}
  end

  @impl true
  def handle_info({:sse_status, status}, state) do
    Logger.warning("[SSEStream] HTTP error status: #{status}")
    Emitter.emit_sse_error(state.job_id, {:http_error, status})
    schedule_reconnect(state)
  end

  @impl true
  def handle_info({:sse_data, data}, state) do
    # Reset heartbeat on any data
    cancel_heartbeat(state.heartbeat_ref)
    heartbeat_ref = schedule_heartbeat_check(state.heartbeat_timeout_ms)

    # Parse SSE frames from buffered data
    {events, new_buffer} = parse_sse_frames(state.buffer <> data)

    # Process each event
    new_state =
      Enum.reduce(events, %{state | heartbeat_ref: heartbeat_ref, buffer: new_buffer}, fn event,
                                                                                          acc ->
        # Call the on_event callback
        acc.on_event.(event)

        # Send event to caller
        send(acc.caller, {:sse_event, acc.job_id, event})

        if terminal_state?(event) do
          send(acc.caller, {:sse_done, acc.job_id, terminal_result(event)})
          # Mark for stop
          Map.put(acc, :should_stop, true)
        else
          acc
        end
      end)

    if Map.get(new_state, :should_stop) do
      {:stop, :normal, new_state}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:sse_closed, reason}, state) do
    Logger.debug("[SSEStream] Connection closed: #{inspect(reason)}")
    cancel_heartbeat(state.heartbeat_ref)
    schedule_reconnect(state)
  end

  @impl true
  def handle_info({:sse_error, reason}, state) do
    Logger.warning("[SSEStream] Error: #{inspect(reason)}")
    Emitter.emit_sse_error(state.job_id, reason)
    cancel_heartbeat(state.heartbeat_ref)
    schedule_reconnect(state)
  end

  @impl true
  def handle_info(:heartbeat_timeout, state) do
    Logger.warning("[SSEStream] Heartbeat timeout for job #{state.job_id}")
    Emitter.emit_sse_heartbeat_timeout(state.job_id)
    kill_task(state.task_pid)
    send(self(), :connect)
    {:noreply, %{state | task_pid: nil, heartbeat_ref: nil, buffer: ""}}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Task completed - ignore, we handle it via messages
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    if state.task_pid && pid == state.task_pid do
      case reason do
        :normal ->
          {:noreply, state}

        :killed ->
          # We killed it intentionally (heartbeat timeout)
          {:noreply, state}

        reason ->
          Logger.debug("[SSEStream] Task down: #{inspect(reason)}")
          schedule_reconnect(state)
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{task_pid: task_pid} = state) when pid == task_pid do
    case reason do
      :normal -> {:noreply, state}
      :killed -> {:noreply, state}
      _reason -> schedule_reconnect(state)
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_heartbeat(state.heartbeat_ref)
    kill_task(state.task_pid)
    :ok
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp start_sse_connection(url, timeout_ms, finch_name) do
    parent = self()

    # Use spawn instead of Task.async to avoid exit signal propagation
    pid =
      spawn(fn ->
        request = Finch.build(:get, url, [{"accept", "text/event-stream"}])

        result =
          Finch.stream(
            request,
            finch_name,
            nil,
            fn
              {:status, status}, acc ->
                send(parent, {:sse_status, status})
                acc

              {:headers, _headers}, acc ->
                acc

              {:data, data}, acc ->
                send(parent, {:sse_data, data})
                acc
            end,
            receive_timeout: timeout_ms
          )

        case result do
          {:ok, _} ->
            send(parent, {:sse_closed, :normal})

          {:error, %Mint.TransportError{reason: :closed}} ->
            send(parent, {:sse_closed, :connection_closed})

          {:error, %Mint.TransportError{reason: :closed}, _state} ->
            send(parent, {:sse_closed, :connection_closed})

          {:error, %Mint.TransportError{reason: reason}} ->
            send(parent, {:sse_error, {:transport_error, reason}})

          {:error, %Mint.TransportError{reason: reason}, _state} ->
            send(parent, {:sse_error, {:transport_error, reason}})

          {:error, reason} ->
            send(parent, {:sse_error, reason})

          {:error, reason, _state} ->
            send(parent, {:sse_error, reason})
        end

        :ok
      end)

    # Monitor the process so we know if it dies
    Process.monitor(pid)

    {:ok, pid}
  rescue
    e ->
      {:error, e}
  end

  defp schedule_reconnect(state) do
    delay = Enum.at(@reconnect_delays, state.reconnect_index, List.last(@reconnect_delays))
    new_index = min(state.reconnect_index + 1, length(@reconnect_delays) - 1)

    Logger.debug("[SSEStream] Reconnecting in #{delay}ms (attempt #{new_index + 1})")
    Emitter.emit_sse_reconnecting(state.job_id, delay)

    Process.send_after(self(), :connect, delay)

    {:noreply,
     %{state | reconnect_index: new_index, task_pid: nil, heartbeat_ref: nil, buffer: ""}}
  end

  defp schedule_heartbeat_check(timeout_ms) do
    Process.send_after(self(), :heartbeat_timeout, timeout_ms)
  end

  defp cancel_heartbeat(nil), do: :ok
  defp cancel_heartbeat(ref), do: Process.cancel_timer(ref)

  defp kill_task(nil), do: :ok

  defp kill_task(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :kill)
    end
  end

  defp parse_sse_frames(data) do
    # Split on double newlines (SSE frame delimiter)
    parts = String.split(data, "\n\n", trim: false)

    case parts do
      [incomplete] ->
        # No complete frame yet
        {[], incomplete}

      frames ->
        # Last part may be incomplete
        {complete, [incomplete]} = Enum.split(frames, -1)

        events =
          complete
          |> Enum.map(&parse_sse_frame/1)
          |> Enum.reject(&is_nil/1)

        {events, incomplete}
    end
  end

  defp parse_sse_frame(frame) do
    lines = String.split(frame, "\n", trim: true)

    event_data =
      Enum.reduce(lines, %{}, fn line, acc ->
        cond do
          String.starts_with?(line, "event:") ->
            Map.put(acc, :event_type, String.trim(String.replace_prefix(line, "event:", "")))

          String.starts_with?(line, "data:") ->
            data_str = String.trim(String.replace_prefix(line, "data:", ""))
            Map.put(acc, :data, data_str)

          String.starts_with?(line, "id:") ->
            Map.put(acc, :id, String.trim(String.replace_prefix(line, "id:", "")))

          String.starts_with?(line, "retry:") ->
            Map.put(acc, :retry, String.trim(String.replace_prefix(line, "retry:", "")))

          true ->
            acc
        end
      end)

    case Map.get(event_data, :data) do
      nil ->
        nil

      data_str ->
        case Jason.decode(data_str) do
          {:ok, parsed} ->
            Map.put(parsed, "event_type", Map.get(event_data, :event_type, "message"))

          {:error, _} ->
            # Skip malformed JSON silently
            nil
        end
    end
  end

  defp terminal_state?(%{"state" => "completed"}), do: true
  defp terminal_state?(%{"state" => "failed"}), do: true
  defp terminal_state?(%{"state" => "cancelled"}), do: true
  defp terminal_state?(_), do: false

  defp terminal_result(%{"state" => "completed"}), do: :completed
  defp terminal_result(%{"state" => "failed"}), do: :failed
  defp terminal_result(%{"state" => "cancelled"}), do: :cancelled
end
