defmodule Medlum.Conversion.Infrastructure.HTTP.Client do
  @moduledoc """
  HTTP client wrapper with trace header injection.

  Wraps Req library, adds context headers, emits telemetry.
  Does NOT implement retry (caller's responsibility for idempotent ops).

  ## Usage

      # Enqueue a job (DO NOT RETRY - not idempotent)
      {:ok, result} = Client.enqueue(binary, opts, base_url: endpoint)

      # Get job status (safe to retry)
      {:ok, status} = Client.job_status(job_id, base_url: endpoint)

      # Health check (safe to retry)
      {:ok, health} = Client.health(base_url: endpoint)
  """

  alias Medlum.Conversion.Infrastructure.Context
  alias Medlum.Conversion.Infrastructure.Telemetry.Emitter

  require Logger

  @default_timeout 15_000
  @enqueue_timeout 60_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Enqueue a file for conversion.

  CRITICAL: Do NOT wrap this in retry logic — it's not idempotent.
  """
  @spec enqueue(binary(), keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue(binary, opts, http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    timeout = Keyword.get(opts, :timeout_ms, @enqueue_timeout)

    fields = build_multipart_fields(binary, opts)

    request(:post, "#{base_url}/jobs",
      form_multipart: fields,
      receive_timeout: timeout
    )
  end

  @doc """
  Get job status.
  """
  @spec job_status(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def job_status(job_id, http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    timeout = Keyword.get(http_opts, :timeout_ms, @default_timeout)

    request(:get, "#{base_url}/jobs/#{job_id}/status", receive_timeout: timeout)
  end

  @doc """
  Check backend health.
  """
  @spec health(keyword()) :: {:ok, map()} | {:error, term()}
  def health(http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    timeout = Keyword.get(http_opts, :timeout_ms, @default_timeout)

    request(:get, "#{base_url}/health", receive_timeout: timeout)
  end

  @doc """
  Cancel a job.
  """
  @spec cancel(String.t(), keyword()) :: :ok | {:error, term()}
  def cancel(job_id, http_opts) do
    base_url = Keyword.fetch!(http_opts, :base_url)
    timeout = Keyword.get(http_opts, :timeout_ms, @default_timeout)

    case request(:delete, "#{base_url}/jobs/#{job_id}", receive_timeout: timeout) do
      {:ok, _} -> :ok
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp request(method, url, opts) do
    headers = Context.to_headers()
    start_time = System.monotonic_time(:millisecond)

    result =
      Req.new(
        method: method,
        url: url,
        headers: headers,
        # Disable Req's built-in retry - we handle retry at a higher level
        retry: false
      )
      |> Req.merge(opts)
      |> Req.request()

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        Emitter.emit_http_request(method, status, duration, :local)
        {:ok, decode_body(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        Emitter.emit_http_request(method, status, duration, :local)
        {:error, {:http_error, status, decode_body(body)}}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.warning("[HTTP.Client] Transport error: #{inspect(reason)}")
        {:error, {:transport_error, reason}}

      {:error, exception} ->
        Logger.warning("[HTTP.Client] Request error: #{inspect(exception)}")
        {:error, {:transport_error, exception}}
    end
  end

  defp build_multipart_fields(binary, opts) do
    filename = Keyword.get(opts, :filename, "document.pdf")
    content_type = Keyword.get(opts, :content_type, "application/pdf")
    byte_size = Keyword.get(opts, :byte_size, byte_size(binary))
    job_id = Keyword.get(opts, :job_id)

    file_field =
      {:file,
       {binary,
        [
          filename: filename,
          content_type: content_type,
          size: byte_size
        ]}}

    fields = [
      file_field,
      {:output_markdown, "true"},
      {:wait, "false"}
    ]

    if job_id do
      [{:job_id, job_id} | fields]
    else
      fields
    end
  end

  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"raw" => body}
    end
  end

  defp decode_body(body), do: %{"raw" => inspect(body)}
end
