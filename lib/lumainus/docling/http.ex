defmodule Lumainus.Docling.HTTP do
  @moduledoc """
  Shared HTTP client for Docling service communication.

  All backends delegate to this module for actual HTTP calls.
  Handles multipart upload, job status polling, and basic operations.

  This module now includes SSE-first awaiting with polling fallback so backends
  can delegate progress handling consistently.
  """

  alias Lumainus.Docling.SSEConsumer
  require Logger

  @default_timeout 1_200_000
  @default_status_timeout 15_000

  @doc """
  Convert a PDF binary to markdown synchronously.

  ## Options
    * `:filename` - Required. The filename for the upload.
    * `:content_type` - Content type (default: "application/pdf")
    * `:byte_size` - Size in bytes (default: calculated from binary)
    * `:timeout_ms` - Request timeout in ms (default: 1,200,000)
    * `:job_id` - Optional job ID to associate

  ## HTTP Options
    * `:base_url` - Required. The Docling service base URL.
  """
  @spec convert(binary(), keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def convert(binary, opts, http_opts) when is_binary(binary) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)

    fields = build_multipart_fields(binary, opts, output_markdown: true)

    request(:post, "#{base_url}/convert",
      form_multipart: fields,
      receive_timeout: timeout
    )
  end

  @doc """
  Enqueue a conversion job asynchronously.

  Returns immediately with job metadata. Use `job_status/2` to poll for results.

  ## Options
    * `:filename` - Required. The filename for the upload.
    * `:content_type` - Content type (default: "application/pdf")
    * `:byte_size` - Size in bytes
    * `:timeout_ms` - Request timeout in ms
    * `:job_id` - Optional job ID to use

  ## HTTP Options
    * `:base_url` - Required. The Docling service base URL.
  """
  @spec enqueue(binary(), keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue(binary, opts, http_opts) when is_binary(binary) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)

    fields = build_multipart_fields(binary, opts, output_markdown: true, wait: false)

    request(:post, "#{base_url}/jobs",
      form_multipart: fields,
      receive_timeout: timeout
    )
  end

  @doc """
  Await a queued job, preferring SSE streaming and falling back to polling.
  """
  @spec await(map(), keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def await(job, opts, http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    on_status = Keyword.get(opts, :on_status, fn _ -> :ok end)
    poll_ms = Keyword.get(opts, :poll_interval_ms, default_poll_interval_ms())
    timeout_ms = Map.get(job, :timeout_ms, @default_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    prefer_sse = prefer_sse?(opts)

    if prefer_sse do
      case await_sse(job.job_id, base_url, deadline, on_status) do
        {:ok, result} ->
          {:ok, result}

        {:fallback, _reason} ->
          poll_status(job.job_id, base_url, deadline, poll_ms, on_status)

        {:error, _} = error ->
          error
      end
    else
      poll_status(job.job_id, base_url, deadline, poll_ms, on_status)
    end
  end

  @doc """
  Get the status of a job.

  ## HTTP Options
    * `:base_url` - Required. The Docling service base URL.
  """
  @spec job_status(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def job_status(job_id, http_opts) when is_binary(job_id) do
    base_url = Keyword.fetch!(http_opts, :base_url)

    request(:get, "#{base_url}/jobs/#{job_id}/status", receive_timeout: @default_status_timeout)
  end

  @doc """
  Check the health of the Docling service.

  ## HTTP Options
    * `:base_url` - Required. The Docling service base URL.
  """
  @spec health(keyword()) :: {:ok, map()} | {:error, term()}
  def health(http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)

    request(:get, "#{base_url}/health", receive_timeout: @default_status_timeout)
  end

  @doc """
  Cancel a running job.

  ## HTTP Options
    * `:base_url` - Required. The Docling service base URL.
  """
  @spec cancel(String.t(), keyword()) :: :ok | {:error, term()}
  def cancel(job_id, http_opts) when is_binary(job_id) do
    base_url = Keyword.fetch!(http_opts, :base_url)

    case request(:delete, "#{base_url}/jobs/#{job_id}", receive_timeout: @default_status_timeout) do
      {:ok, _} -> :ok
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Build multipart form fields for file upload.

  ## Options
    * `:filename` - Required. The filename.
    * `:content_type` - Content type (default: "application/pdf")
    * `:byte_size` - Size in bytes
    * `:job_id` - Optional job ID

  ## Extra Options
    * `:output_markdown` - Add output_markdown=true field
    * `:wait` - Add wait field (false for async)
  """
  @spec build_multipart_fields(binary(), keyword(), keyword()) :: list()
  def build_multipart_fields(binary, opts, extra \\ []) do
    filename = Keyword.fetch!(opts, :filename)
    content_type = Keyword.get(opts, :content_type, "application/pdf")
    byte_size = Keyword.get(opts, :byte_size, byte_size(binary))
    job_id = Keyword.get(opts, :job_id)

    fields = [
      {:file, {binary, filename: filename, content_type: content_type, size: byte_size}}
    ]

    fields =
      if Keyword.get(extra, :output_markdown),
        do: [{:output_markdown, "true"} | fields],
        else: fields

    fields =
      if Keyword.has_key?(extra, :wait) and extra[:wait] == false,
        do: [{:wait, "false"} | fields],
        else: fields

    fields =
      if job_id,
        do: [{:job_id, job_id} | fields],
        else: fields

    fields
  end

  @doc """
  Decode a response body.

  Handles JSON strings, maps, and other values.
  """
  @spec decode_body(term()) :: map()
  def decode_body(%{} = body), do: body

  def decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"raw" => body}
    end
  end

  def decode_body(body), do: %{"raw" => inspect(body)}

  # Private functions

  defp await_sse(job_id, base_url, deadline, on_status) do
    timeout = max(0, deadline - System.monotonic_time(:millisecond))

    {:ok, task} = SSEConsumer.subscribe(job_id, timeout: timeout, base_url: base_url)
    result = receive_sse_events(job_id, task, base_url, deadline, on_status)
    SSEConsumer.cancel(task)
    result
  end

  defp receive_sse_events(job_id, task, base_url, deadline, on_status) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:sse_event, ^job_id, event} ->
        status = sse_event_to_status(event)
        on_status.(status)
        receive_sse_events(job_id, task, base_url, deadline, on_status)

      {:sse_done, ^job_id, :completed} ->
        case job_status(job_id, base_url: base_url) do
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
        case job_status(job_id, base_url: base_url) do
          {:ok, %{"last_error" => error}} -> {:error, {:docling_failed, error}}
          _ -> {:error, {:docling_failed, nil}}
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

  defp poll_status(job_id, base_url, deadline, poll_ms, on_status) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        {:error, :timeout}

      true ->
        case job_status(job_id, base_url: base_url) do
          {:ok, %{"state" => "completed"} = body} ->
            on_status.(body)
            {:ok, Map.get(body, "result") || Map.get(body, "payload") || %{}}

          {:ok, %{"state" => "failed"} = body} ->
            on_status.(body)
            {:error, {:docling_failed, body["last_error"]}}

          {:ok, pending} ->
            on_status.(pending)
            Process.sleep(poll_ms)
            poll_status(job_id, base_url, deadline, poll_ms, on_status)

          {:error, reason} ->
            {:error, reason}
        end
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

  defp default_poll_interval_ms do
    Application.get_env(:lumainus, :docling, [])
    |> Keyword.get(:poll_interval_ms, 5_000)
  end

  defp prefer_sse?(opts) do
    case Keyword.fetch(opts, :prefer_sse) do
      {:ok, value} -> value
      :error -> Application.get_env(:lumainus, :docling, []) |> Keyword.get(:prefer_sse, true)
    end
  end

  defp request(method, url, opts) do
    req_opts =
      Application.get_env(:lumainus, :docling, [])
      |> Keyword.get(:req_opts, [])

    case Req.request([method: method, url: url, retry: false] ++ req_opts ++ opts) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, decode_body(resp.body)}

      {:ok, %{status: status, body: body}} ->
        log(:warning, "Docling HTTP #{method} #{url} returned status #{status}")
        {:error, {:http_error, status, decode_body(body)}}

      {:error, %Req.TransportError{reason: reason}} ->
        log(:error, "Docling HTTP #{method} #{url} transport error: #{inspect(reason)}")
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        log(:error, "Docling HTTP #{method} #{url} request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp log(level, message) do
    suppress? =
      Application.get_env(:lumainus, :docling, [])
      |> Keyword.get(:suppress_logs, false)

    if not suppress? do
      Logger.log(level, message)
    end
  end
end
