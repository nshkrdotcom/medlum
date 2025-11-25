defmodule Lumainus.Docling.Backends.VastAI do
  @moduledoc """
  Vast.ai GPU backend with automatic instance provisioning.

  Provisions RTX 3090 instances on-demand via Vast.ai API.
  Instances are kept alive while jobs are running, then destroyed after idle timeout.

  ## Configuration

      config :lumainus, :docling,
        backend: :vast_ai,
        vast_ai: [
          api_key: "...",
          gpu_name: "RTX_3090",
          min_disk_gb: 20,
          idle_timeout_minutes: 15
        ]

  Requires: VAST_API_KEY environment variable (or config)
  """

  @behaviour Lumainus.Docling.Backend

  alias Lumainus.Docling.HTTP
  alias Lumainus.Docling.VastAI.InstanceManager
  alias Lumainus.Docling.VastAI.ActivityTracker

  @default_timeout 1_200_000

  @impl true
  def convert(binary, opts) when is_binary(binary) do
    with {:ok, endpoint} <- InstanceManager.ensure_instance() do
      record_activity()
      HTTP.convert(binary, opts, base_url: endpoint)
    end
  end

  @impl true
  def enqueue(binary, opts) when is_binary(binary) do
    with {:ok, endpoint} <- InstanceManager.ensure_instance(),
         {:ok, response} <- HTTP.enqueue(binary, opts, base_url: endpoint) do
      record_activity()
      {:ok, build_job(response, opts, endpoint)}
    end
  end

  @impl true
  def await(job, opts \\ []) do
    endpoint = job.metadata.endpoint
    result = HTTP.await(job, opts, base_url: endpoint)

    # Update activity after job completes
    record_activity()

    result
  end

  # Record activity in both trackers
  defp record_activity do
    InstanceManager.update_activity()
    ActivityTracker.record_activity()
  end

  @impl true
  def health do
    case InstanceManager.get_endpoint() do
      {:ok, endpoint} ->
        HTTP.health(base_url: endpoint)

      {:error, :no_instance} ->
        {:ok, %{"status" => "no_instance", "message" => "No active Vast.ai instance"}}
    end
  end

  @impl true
  def cancel(job_id) when is_binary(job_id) do
    case InstanceManager.get_endpoint() do
      {:ok, endpoint} ->
        HTTP.cancel(job_id, base_url: endpoint)

      {:error, :no_instance} ->
        {:error, :no_instance}
    end
  end

  @impl true
  def capabilities, do: [:sync, :async, :sse, :cancel, :auto_provision, :gpu]

  # Private functions

  defp build_job(response, opts, endpoint) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout)

    %{
      job_id: response["job_id"],
      timeout_ms: timeout_ms,
      timeout_at:
        DateTime.utc_now()
        |> DateTime.add(timeout_ms, :millisecond)
        |> DateTime.truncate(:second),
      backend: __MODULE__,
      metadata: %{
        endpoint: endpoint,
        instance_id: InstanceManager.current_instance_id()
      }
    }
  end
end
