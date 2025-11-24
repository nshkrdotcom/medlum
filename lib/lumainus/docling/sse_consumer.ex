defmodule Lumainus.Docling.SSEConsumer do
  @moduledoc """
  Consumes Server-Sent Events from Docling's `/jobs/:id/stream` endpoint.

  Spawns a supervised task that streams events and forwards them to the caller.
  Falls back to polling on connection failure.
  """

  require Logger

  @doc """
  Subscribe to SSE stream for a Docling job.

  Returns `{:ok, task_ref}` on success. Events are sent to the caller as:
  - `{:sse_event, job_id, event_map}`
  - `{:sse_done, job_id, :completed | :failed | :timeout}`
  - `{:sse_error, job_id, reason}`

  Options:
  - `:timeout` - Stream timeout in ms (default: 300_000)
  """
  def subscribe(job_id, opts \\ []) do
    caller = self()
    timeout = Keyword.get(opts, :timeout, 300_000)
    base_url = Keyword.fetch!(opts, :base_url)
    url = "#{base_url}/jobs/#{job_id}/stream"

    task =
      Task.Supervisor.async_nolink(
        Lumainus.TaskSupervisor,
        fn -> stream_events(caller, job_id, url, timeout) end
      )

    {:ok, task}
  end

  @doc """
  Cancel an SSE subscription task.
  """
  def cancel(%Task{} = task) do
    Task.Supervisor.terminate_child(Lumainus.TaskSupervisor, task.pid)
    :ok
  end

  def cancel(_), do: :ok

  defp stream_events(caller, job_id, url, timeout) do
    Logger.info("SSE consumer connecting to #{url} (timeout=#{timeout}ms)")

    request = Finch.build(:get, url, [{"accept", "text/event-stream"}])

    result =
      Finch.stream(
        request,
        Lumainus.Finch,
        {caller, job_id, ""},
        fn
          {:status, status}, {caller, job_id, buffer} ->
            if status != 200 do
              send(caller, {:sse_error, job_id, {:http_status, status}})
            end

            {caller, job_id, buffer}

          {:headers, _headers}, acc ->
            acc

          {:data, data}, {caller, job_id, buffer} ->
            {events, new_buffer} = parse_sse_frames(buffer <> data)

            for event <- events do
              send(caller, {:sse_event, job_id, event})

              if terminal_event?(event) do
                state = Map.get(event, "state", "completed")
                send(caller, {:sse_done, job_id, String.to_atom(state)})
              end
            end

            {caller, job_id, new_buffer}
        end,
        receive_timeout: timeout
      )

    case result do
      {:ok, _} ->
        Logger.info("SSE stream ended normally for job #{job_id}")

      {:error, %Mint.TransportError{reason: :closed}} ->
        Logger.info("SSE connection closed for job #{job_id}")
        send(caller, {:sse_error, job_id, :connection_closed})

      {:error, reason} ->
        Logger.warning("SSE stream error for job #{job_id}: #{inspect(reason)}")
        send(caller, {:sse_error, job_id, reason})
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
            %{"raw" => data_str, "event_type" => Map.get(event_data, :event_type, "message")}
        end
    end
  end

  defp terminal_event?(%{"type" => type}) when type in ["completed", "failed", "timeout"],
    do: true

  defp terminal_event?(%{"state" => state}) when state in ["completed", "failed"], do: true
  defp terminal_event?(_), do: false
end
