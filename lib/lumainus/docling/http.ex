defmodule Lumainus.Docling.HTTP do
  @moduledoc """
  Shared HTTP client for Docling service communication.

  All backends delegate to this module for actual HTTP calls.
  Handles multipart upload, job status polling, and basic operations.

  This module is intentionally low-level - it doesn't know about SSE streaming
  or complex polling logic. Those are handled by higher-level modules.
  """

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

  defp request(method, url, opts) do
    case Req.request([method: method, url: url] ++ opts) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, decode_body(resp.body)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Docling HTTP #{method} #{url} returned status #{status}")
        {:error, {:http_error, status, decode_body(body)}}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("Docling HTTP #{method} #{url} transport error: #{inspect(reason)}")
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        Logger.error("Docling HTTP #{method} #{url} request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
