defmodule Lumainus.Docling.Backends.Local do
  @moduledoc """
  Local Docling backend for development.

  Expects Docling service running on localhost:8042 (CPU mode).
  This is the default backend - no cloud setup required.

  ## Configuration

      config :lumainus, :docling,
        backend: :local,
        local_url: "http://127.0.0.1:8042"
  """

  @behaviour Lumainus.Docling.Backend

  alias Lumainus.Docling.HTTP

  @default_url "http://127.0.0.1:8042"
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
    Application.get_env(:lumainus, :docling, [])
    |> Keyword.get(:local_url, @default_url)
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
