defmodule Lumainus.Docling do
  @moduledoc """
  HTTP client and helpers for interacting with the Docling ingestion service.
  """

  import Ecto.Query, warn: false
  alias Lumainus.Docling.HealthCheck
  alias Lumainus.Repo

  require Logger

  @doc """
  Convert a binary PDF into markdown using the Docling REST API.
  """
  def convert(binary, opts) when is_binary(binary) do
    filename = Keyword.fetch!(opts, :filename)
    content_type = Keyword.get(opts, :content_type, "application/pdf")
    upload_id = Keyword.get(opts, :upload_id)
    job_id = Keyword.get(opts, :job_id)
    byte_size = Keyword.get(opts, :byte_size, byte_size(binary))
    timeout_ms = Keyword.get(opts, :timeout_ms, timeout())
    metadata = Logger.metadata()

    Logger.metadata(
      metadata ++
        [docling_upload_id: upload_id, docling_job_id: job_id, docling_filename: filename]
    )

    fields =
      [
        {:output_markdown, "true"},
        {:file,
         {binary,
          filename: filename,
          content_type: content_type,
          size: Keyword.get(opts, :byte_size, byte_size(binary))}}
      ]

    Logger.info("Docling convert start (#{byte_size} bytes, timeout=#{timeout_ms}ms)")
    started = System.monotonic_time(:millisecond)

    response =
      request(:post, "/convert",
        form_multipart: fields,
        receive_timeout: timeout_ms
      )

    duration = System.monotonic_time(:millisecond) - started

    case response do
      {:ok, _} = ok ->
        Logger.info("Docling convert succeeded in #{duration}ms")
        Logger.metadata(metadata)
        ok

      {:error, reason} = error ->
        Logger.error("Docling convert errored in #{duration}ms: #{inspect(reason)}")
        Logger.metadata(metadata)
        error
    end
  end

  def enqueue_job(binary, opts) when is_binary(binary) do
    filename = Keyword.fetch!(opts, :filename)
    content_type = Keyword.get(opts, :content_type, "application/pdf")
    job_id = Keyword.get(opts, :job_id)
    byte_size = Keyword.get(opts, :byte_size, byte_size(binary))
    timeout_ms = Keyword.get(opts, :timeout_ms, timeout())

    fields =
      [
        {:output_markdown, "true"},
        {:wait, "false"},
        {:file,
         {binary,
          filename: filename,
          content_type: content_type,
          size: Keyword.get(opts, :byte_size, byte_size(binary))}}
      ]
      |> maybe_add_job_id(job_id)

    Logger.info("Docling enqueue start (#{byte_size} bytes, timeout=#{timeout_ms}ms)")

    request(:post, "/jobs",
      form_multipart: fields,
      receive_timeout: timeout_ms
    )
  end

  def job_status(job_id) when is_binary(job_id) do
    request(:get, "/jobs/#{job_id}/status", receive_timeout: min(timeout(), 15_000))
  end

  @doc """
  Hit the Docling health endpoint.
  """
  def health do
    request(:get, "/health", receive_timeout: min(timeout(), 15_000))
  end

  def record_health(result) do
    payload =
      case result do
        {:ok, body} ->
          %{
            status: "healthy",
            details: body,
            responded_at: DateTime.utc_now(:second)
          }

        {:error, reason} ->
          %{
            status: "unreachable",
            details: %{error: inspect(reason)}
          }
      end

    record =
      %HealthCheck{}
      |> HealthCheck.changeset(payload)
      |> Repo.insert!()

    {:ok, record}
  end

  def latest_health_check do
    HealthCheck
    |> order_by([h], desc: h.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def base_url do
    config()[:base_url] || raise ArgumentError, "set :docling base_url config"
  end

  def timeout do
    config()[:request_timeout] || 1_200_000
  end

  def config do
    Application.get_env(:lumainus, :docling, [])
  end

  defp request(method, path, opts) do
    url = base_url() <> path

    case Req.request([method: method, url: url] ++ opts) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, decode_body(resp.body)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Docling returned status #{status}")
        {:error, {:http_error, status, decode_body(body)}}

      {:error, reason} ->
        Logger.error("Docling request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp decode_body(%{} = body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{"raw" => body}
    end
  end

  defp decode_body(body), do: body

  defp maybe_add_job_id(fields, nil), do: fields
  defp maybe_add_job_id(fields, job_id), do: [{:job_id, job_id} | fields]
end
