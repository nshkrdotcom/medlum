defmodule Lumainus.Docling.Backends.Remote do
  @moduledoc """
  Remote HTTP backend for any Docling service endpoint.

  Use this for pre-provisioned GPU servers or shared services.

  ## Configuration

      config :lumainus, :docling,
        backend: :remote,
        remote_url: "http://gpu-server:8042"

  Or via environment variable:

      config :lumainus, :docling,
        backend: :remote,
        remote_url: System.get_env("DOCLING_URL")
  """

  @behaviour Lumainus.Docling.Backend

  alias Lumainus.Docling.HTTP

  @default_timeout 1_200_000

  @impl true
  def convert(binary, opts) when is_binary(binary) do
    HTTP.convert(binary, opts, base_url: url())
  end

  @impl true
  def enqueue(binary, opts) when is_binary(binary) do
    case HTTP.enqueue(binary, opts, base_url: url()) do
      {:ok, response} ->
        {:ok, build_job(response, opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def await(job, opts \\ []) do
    HTTP.await(job, opts, base_url: url())
  end

  @impl true
  def health do
    HTTP.health(base_url: url())
  end

  @impl true
  def cancel(job_id) when is_binary(job_id) do
    HTTP.cancel(job_id, base_url: url())
  end

  @impl true
  def capabilities, do: [:sync, :async, :sse, :cancel]

  # Private functions

  defp url do
    config = Application.get_env(:lumainus, :docling, [])

    case Keyword.get(config, :remote_url) || Keyword.get(config, :base_url) do
      nil -> raise "Remote backend requires :docling :remote_url config"
      url -> url
    end
  end

  defp build_job(response, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout)

    %{
      job_id: response["job_id"],
      timeout_ms: timeout_ms,
      timeout_at:
        DateTime.utc_now()
        |> DateTime.add(timeout_ms, :millisecond)
        |> DateTime.truncate(:second),
      backend: __MODULE__,
      metadata: %{url: url()}
    }
  end
end
