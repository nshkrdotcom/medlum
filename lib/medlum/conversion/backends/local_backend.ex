defmodule Medlum.Conversion.Backends.LocalBackend do
  @moduledoc """
  Backend for local CPU/GPU instances (native or Docker).

  Delegates HTTP operations to shared client module.

  ## Configuration

  Local backends are configured via application config:

      config :medlum, :conversion,
        native_cpu_url: "http://localhost:8040",
        native_gpu_url: "http://localhost:8041",
        docker_cpu_url: "http://localhost:8042",
        docker_gpu_url: "http://localhost:8043",
        active_local_backend: :docker_cpu

  ## Usage

      # Enqueue a job
      {:ok, job} = LocalBackend.enqueue(binary, filename: "doc.pdf")

      # Check status
      {:ok, status} = LocalBackend.status(job_id)

      # Await completion
      {:ok, result} = LocalBackend.await(job_ref, on_status: &handle_progress/1)
  """

  @behaviour Medlum.Conversion.Backend

  alias Medlum.Conversion.Infrastructure.HTTP.Client
  alias Medlum.Conversion.Infrastructure.HTTP.SSEStream

  require Logger

  # ============================================================================
  # Backend Callbacks
  # ============================================================================

  @impl true
  def enqueue(binary, opts) when is_binary(binary) do
    endpoint = get_endpoint(opts)

    Client.enqueue(binary, opts, base_url: endpoint)
  end

  @impl true
  def await(job_ref, opts) do
    endpoint = get_endpoint_from_job_ref(job_ref, opts)
    job_id = job_ref[:job_id]
    timeout_ms = Keyword.get(opts, :timeout_ms, job_ref[:timeout_ms] || 300_000)
    on_status = Keyword.get(opts, :on_status, fn _ -> :ok end)

    SSEStream.await(job_id,
      base_url: endpoint,
      timeout_ms: timeout_ms,
      on_status: on_status
    )
  end

  @impl true
  def status(job_id, opts \\ []) do
    endpoint = get_endpoint(opts)

    Client.job_status(job_id, base_url: endpoint)
  end

  @impl true
  def cancel(job_id, opts \\ []) do
    endpoint = get_endpoint(opts)

    Client.cancel(job_id, base_url: endpoint)
  end

  @impl true
  def health(opts \\ []) do
    endpoint = get_endpoint(opts)

    Client.health(base_url: endpoint, timeout_ms: 10_000)
  end

  @impl true
  def name(opts \\ []) do
    case Keyword.get(opts, :backend_name) do
      nil -> get_backend_name()
      name -> name
    end
  end

  @impl true
  def backend_type, do: :local

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_endpoint(opts) do
    case Keyword.get(opts, :endpoint) do
      nil -> get_active_endpoint()
      endpoint -> endpoint
    end
  end

  defp get_endpoint_from_job_ref(job_ref, opts) do
    # Try from opts first, then job_ref metadata, then default
    case Keyword.get(opts, :endpoint) do
      nil ->
        case job_ref do
          %{metadata: %{endpoint: endpoint}} when is_binary(endpoint) -> endpoint
          _ -> get_active_endpoint()
        end

      endpoint ->
        endpoint
    end
  end

  defp get_active_endpoint do
    config = Application.get_env(:medlum, :conversion, [])
    backend = config[:active_local_backend] || :docker_cpu

    case backend do
      :native_cpu -> config[:native_cpu_url] || "http://localhost:8040"
      :native_gpu -> config[:native_gpu_url] || "http://localhost:8041"
      :docker_cpu -> config[:docker_cpu_url] || "http://localhost:8042"
      :docker_gpu -> config[:docker_gpu_url] || "http://localhost:8043"
      :local_cpu -> config[:native_cpu_url] || "http://localhost:8040"
      :local_gpu -> config[:native_gpu_url] || "http://localhost:8041"
      _ -> "http://localhost:8042"
    end
  end

  defp get_backend_name do
    config = Application.get_env(:medlum, :conversion, [])
    config[:active_local_backend] || :docker_cpu
  end
end
