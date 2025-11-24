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
    on_status = Keyword.get(opts, :on_status, fn _ -> :ok end)
    poll_ms = Keyword.get(opts, :poll_interval_ms, 5_000)
    deadline = System.monotonic_time(:millisecond) + job.timeout_ms

    poll_until_complete(job.job_id, deadline, poll_ms, on_status)
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
    |> Keyword.get(:remote_url)
    |> case do
      nil -> raise "Remote backend requires :docling :remote_url config"
      url -> url
    end
  end

  defp build_job(response, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout)

    %{
      job_id: response["job_id"],
      timeout_ms: timeout_ms,
      timeout_at: DateTime.add(DateTime.utc_now(), timeout_ms, :millisecond),
      backend: __MODULE__,
      metadata: %{url: url()}
    }
  end

  defp poll_until_complete(job_id, deadline, poll_ms, on_status) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case HTTP.job_status(job_id, base_url: url()) do
        {:ok, %{"state" => "completed"} = body} ->
          on_status.(body)
          {:ok, Map.get(body, "result") || Map.get(body, "payload") || body}

        {:ok, %{"state" => "failed"} = body} ->
          on_status.(body)
          {:error, {:docling_failed, body["last_error"]}}

        {:ok, pending} ->
          on_status.(pending)
          Process.sleep(poll_ms)
          poll_until_complete(job_id, deadline, poll_ms, on_status)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
