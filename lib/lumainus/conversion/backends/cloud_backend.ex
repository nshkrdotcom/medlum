defmodule Lumainus.Conversion.Backends.CloudBackend do
  @moduledoc """
  Backend for Vast.ai cloud GPU instances.

  Handles automatic instance provisioning via InstanceManager.
  Provisioning state is surfaced through health/status.

  ## Important: Uses Existing InstanceManager

  This backend delegates instance management to the existing
  `Lumainus.Docling.VastAI.InstanceManager` module. Do NOT rewrite
  Vast.ai provisioning logic here.

  ## Usage

      # Enqueue a job (will provision instance if needed)
      {:ok, job} = CloudBackend.enqueue(binary, filename: "doc.pdf")

      # Check status
      {:ok, status} = CloudBackend.status(job_id)

      # Await completion
      {:ok, result} = CloudBackend.await(job_ref, on_status: &handle_progress/1)
  """

  @behaviour Lumainus.Conversion.Backend

  alias Lumainus.Conversion.Infrastructure.HTTP.Client
  alias Lumainus.Docling.VastAI.InstanceManager
  alias Lumainus.Docling.VastAI.ActivityTracker

  require Logger

  # ============================================================================
  # Backend Callbacks
  # ============================================================================

  @impl true
  def enqueue(binary, opts) when is_binary(binary) do
    ensure_fn = Keyword.get(opts, :ensure_instance_fn, &default_ensure_instance/0)

    case ensure_fn.() do
      {:ok, endpoint} ->
        record_activity(opts)
        Client.enqueue(binary, opts, base_url: endpoint)

      {:error, :no_instance} ->
        {:ok, %{"state" => "provisioning"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def await(job_ref, opts) do
    get_endpoint_fn = Keyword.get(opts, :get_endpoint_fn, &default_get_endpoint/0)

    case get_endpoint_fn.() do
      {:ok, endpoint} ->
        result = Client.await(job_ref, opts, base_url: endpoint)
        record_activity(opts)
        result

      {:error, :no_instance} ->
        {:error, :no_instance}
    end
  end

  @impl true
  def status(job_id, opts \\ []) do
    get_endpoint_fn = Keyword.get(opts, :get_endpoint_fn, &default_get_endpoint/0)

    case get_endpoint_fn.() do
      {:ok, endpoint} ->
        Client.job_status(job_id, base_url: endpoint)

      {:error, :no_instance} ->
        {:ok, %{"state" => "provisioning"}}
    end
  end

  @impl true
  def cancel(job_id, opts \\ []) do
    get_endpoint_fn = Keyword.get(opts, :get_endpoint_fn, &default_get_endpoint/0)

    case get_endpoint_fn.() do
      {:ok, endpoint} ->
        Client.cancel(job_id, base_url: endpoint)

      {:error, :no_instance} ->
        {:error, :no_instance}
    end
  end

  @impl true
  def health(opts \\ []) do
    get_endpoint_fn = Keyword.get(opts, :get_endpoint_fn, &default_get_endpoint/0)
    status_fn = Keyword.get(opts, :instance_status_fn, &default_instance_status/0)

    case get_endpoint_fn.() do
      {:ok, endpoint} ->
        Client.health(base_url: endpoint, timeout_ms: 20_000)

      {:error, :no_instance} ->
        case status_fn.() do
          :loading -> {:ok, %{"status" => "provisioning"}}
          _ -> {:error, :no_instance}
        end
    end
  end

  @impl true
  def name, do: :cloud

  @impl true
  def backend_type, do: :cloud

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp default_ensure_instance do
    if process_running?(InstanceManager) do
      InstanceManager.ensure_instance()
    else
      {:error, :instance_manager_not_running}
    end
  end

  defp default_get_endpoint do
    if process_running?(InstanceManager) do
      InstanceManager.get_endpoint()
    else
      fallback_cloud_url()
    end
  end

  defp default_instance_status do
    if process_running?(InstanceManager) do
      case InstanceManager.status() do
        %{status: status} -> status
        status when is_atom(status) -> status
        _ -> :none
      end
    else
      :none
    end
  end

  defp fallback_cloud_url do
    case Application.get_env(:lumainus, :conversion, [])[:cloud_url] do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, :no_instance}
    end
  end

  defp record_activity(opts) do
    update_fn = Keyword.get(opts, :update_activity_fn, &default_update_activity/0)
    update_fn.()
  end

  defp default_update_activity do
    if process_running?(InstanceManager) do
      InstanceManager.update_activity()
    end

    if process_running?(ActivityTracker) do
      ActivityTracker.record_activity()
    end

    :ok
  end

  defp process_running?(module) do
    case Process.whereis(module) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end
end
