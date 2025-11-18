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

    fields =
      [
        {:output_markdown, "true"},
        {:file,
         {binary,
          filename: filename,
          content_type: content_type,
          size: Keyword.get(opts, :byte_size, byte_size(binary))}}
      ]

    request(:post, "/convert",
      form_multipart: fields,
      receive_timeout: timeout()
    )
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
    config()[:request_timeout] || 60_000
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
end
