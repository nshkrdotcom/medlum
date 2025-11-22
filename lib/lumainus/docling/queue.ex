defmodule Lumainus.Docling.Queue do
  @moduledoc """
  Queue facade for Docling. Defaults to inline conversion but can poll the
  Docling service's `/jobs` endpoint when `:queue_mode` is set to `:http_queue`.

  When in HTTP queue mode, attempts SSE streaming first for real-time updates,
  falling back to slower polling (5s) if the stream fails.
  """

  alias Lumainus.Docling
  alias Lumainus.Docling.SSEConsumer
  require Logger

  @inline_mode :inline
  @default_poll_interval_ms 5_000

  @type job :: %{
          job_id: binary(),
          timeout_ms: non_neg_integer(),
          timeout_at: DateTime.t(),
          mode: atom(),
          binary: binary() | nil,
          convert_opts: keyword()
        }

  @doc """
  Enqueue a Docling job and return a handle that can be awaited.
  """
  def enqueue(binary, opts \\ []) when is_binary(binary) do
    mode = queue_mode()
    timeout_ms = Keyword.get(opts, :timeout_ms, Docling.timeout())
    job_id = Keyword.get(opts, :job_id, Ecto.UUID.generate())
    timeout_at = DateTime.utc_now(:second) |> DateTime.add(div(timeout_ms, 1000), :second)

    Logger.info("Submitting Docling job #{job_id} (mode=#{mode}, timeout=#{timeout_ms}ms)")

    payload = %{
      job_id: job_id,
      timeout_ms: timeout_ms,
      timeout_at: timeout_at,
      mode: mode,
      binary: binary,
      convert_opts: Keyword.merge(opts, job_id: job_id)
    }

    case mode do
      :http_queue -> enqueue_remote(payload)
      _ -> {:ok, payload}
    end
  end

  @doc """
  Await a Docling job. Inline mode runs the conversion directly; HTTP queue mode
  uses SSE streaming first, falling back to polling if the stream fails.
  """
  def await(job, opts \\ [])

  def await(%{mode: :http_queue} = job, opts) do
    on_status = Keyword.get(opts, :on_status, fn _ -> :ok end)
    deadline = System.monotonic_time(:millisecond) + job.timeout_ms + 5_000

    Logger.info("Docling queue await: attempting SSE for job #{job.job_id}")

    # Try SSE first, fall back to polling on error
    case await_sse(job, deadline, on_status) do
      {:ok, result} ->
        {:ok, result}

      {:fallback, reason} ->
        Logger.info(
          "SSE failed (#{inspect(reason)}), falling back to polling for job #{job.job_id}"
        )

        poll_ms = Keyword.get(opts, :poll_interval_ms, poll_interval_ms())
        poll_remote(job, deadline, poll_ms, on_status)

      {:error, _} = error ->
        error
    end
  end

  def await(%{mode: _} = job, _opts) do
    Docling.convert(job.binary, Keyword.put(job.convert_opts, :timeout_ms, job.timeout_ms))
  end

  defp await_sse(job, deadline, on_status) do
    timeout = max(0, deadline - System.monotonic_time(:millisecond))

    case SSEConsumer.subscribe(job.job_id, timeout: timeout) do
      {:ok, task} ->
        result = receive_sse_events(job.job_id, task, deadline, on_status)
        SSEConsumer.cancel(task)
        result

      {:error, reason} ->
        {:fallback, reason}
    end
  end

  defp receive_sse_events(job_id, task, deadline, on_status) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:sse_event, ^job_id, event} ->
        # Forward event to status handler
        status = sse_event_to_status(event)
        on_status.(status)
        receive_sse_events(job_id, task, deadline, on_status)

      {:sse_done, ^job_id, :completed} ->
        # Fetch final result from status endpoint
        case Docling.job_status(job_id) do
          {:ok, %{"state" => "completed", "result" => result}} when not is_nil(result) ->
            {:ok, result}

          {:ok, %{"state" => "completed"} = body} ->
            {:ok, Map.get(body, "result") || Map.get(body, "payload") || %{}}

          {:ok, body} ->
            {:error, {:unexpected_state, body}}

          {:error, reason} ->
            {:error, reason}
        end

      {:sse_done, ^job_id, :failed} ->
        case Docling.job_status(job_id) do
          {:ok, %{"last_error" => error}} ->
            {:error, {:docling_failed, error}}

          _ ->
            {:error, {:docling_failed, nil}}
        end

      {:sse_done, ^job_id, :timeout} ->
        {:error, :timeout}

      {:sse_error, ^job_id, reason} ->
        {:fallback, reason}

      {:DOWN, _ref, :process, _pid, reason} ->
        {:fallback, {:task_down, reason}}
    after
      remaining ->
        {:error, :timeout}
    end
  end

  defp sse_event_to_status(event) do
    %{
      "state" => Map.get(event, "state", "running"),
      "progress" => Map.get(event, "progress"),
      "pages_done" => Map.get(event, "pages_done"),
      "pages_total" => Map.get(event, "pages_total"),
      "last_message" => Map.get(event, "message"),
      "worker_id" => Map.get(event, "worker_id"),
      "device" => Map.get(event, "device"),
      "queue_depth" => Map.get(event, "queue_depth"),
      "type" => Map.get(event, "type"),
      "stage" => Map.get(event, "stage")
    }
  end

  def queue_mode do
    Application.get_env(:lumainus, :docling, []) |> Keyword.get(:queue_mode, @inline_mode)
  end

  defp poll_interval_ms do
    Application.get_env(:lumainus, :docling, [])
    |> Keyword.get(:poll_interval_ms, @default_poll_interval_ms)
  end

  defp enqueue_remote(job) do
    case Docling.enqueue_job(
           job.binary,
           Keyword.put(job.convert_opts, :timeout_ms, job.timeout_ms)
         ) do
      {:ok, %{"job_id" => remote_id}} ->
        {:ok,
         %{
           job
           | job_id: remote_id,
             convert_opts: Keyword.put(job.convert_opts, :job_id, remote_id),
             binary: nil
         }}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp poll_remote(job, deadline, poll_ms, on_status) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        {:error, :timeout}

      true ->
        case Docling.job_status(job.job_id) do
          {:ok, %{"state" => "completed"} = body} ->
            on_status.(body)
            {:ok, Map.get(body, "result") || Map.get(body, "payload") || %{}}

          {:ok, %{"state" => "failed"} = body} ->
            on_status.(body)
            {:error, {:docling_failed, body["last_error"]}}

          {:ok, pending} ->
            on_status.(pending)
            Process.sleep(poll_ms)
            poll_remote(job, deadline, poll_ms, on_status)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
