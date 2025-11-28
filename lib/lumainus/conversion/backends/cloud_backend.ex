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

  alias Lumainus.Conversion.CloudStatus
  alias Lumainus.Conversion.Infrastructure.HTTP.Client
  alias Lumainus.Docling.VastAI.InstanceManager
  alias Lumainus.Docling.VastAI.ActivityTracker

  require Logger

  # Max time to wait for instance to become ready (5 minutes)
  @provisioning_timeout_ms 300_000
  # Poll interval when waiting for provisioning
  @provisioning_poll_ms 5_000

  # ============================================================================
  # Backend Callbacks
  # ============================================================================

  @impl true
  def enqueue(binary, opts) when is_binary(binary) do
    timeout_ms = Keyword.get(opts, :provisioning_timeout_ms, @provisioning_timeout_ms)

    # Wait for cloud to be ready (may trigger provisioning)
    case wait_for_ready(timeout_ms, opts) do
      {:ok, endpoint} ->
        record_activity(opts)
        Client.enqueue(binary, opts, base_url: endpoint)

      {:error, :provisioning_timeout} ->
        {:error,
         {:provisioning_timeout,
          "Cloud GPU provisioning timed out after #{div(timeout_ms, 60_000)} minutes"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def await(job_ref, opts) do
    # For await, use shorter timeout since instance should already be provisioned
    timeout_ms = Keyword.get(opts, :await_provisioning_timeout_ms, 60_000)

    case wait_for_ready(timeout_ms, opts) do
      {:ok, endpoint} ->
        result = Client.await(job_ref, opts, base_url: endpoint)
        record_activity(opts)
        result

      {:error, :provisioning_timeout} ->
        {:error, {:provisioning_timeout, "Cloud GPU not ready for job processing"}}

      {:error, reason} ->
        {:error, reason}
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

  # Wait for cloud instance to become ready, triggering provisioning if needed.
  # Returns {:ok, endpoint} when ready, {:error, reason} on failure/timeout.
  defp wait_for_ready(timeout_ms, opts) do
    ensure_fn = Keyword.get(opts, :ensure_instance_fn, &default_ensure_instance/0)
    cloud_status_fn = Keyword.get(opts, :cloud_status_fn, &CloudStatus.get/0)
    poll_ms = Keyword.get(opts, :poll_interval_ms, @provisioning_poll_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait_for_ready(ensure_fn, cloud_status_fn, poll_ms, deadline)
  end

  defp do_wait_for_ready(ensure_fn, cloud_status_fn, poll_ms, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :provisioning_timeout}
    else
      case cloud_status_fn.() do
        %{availability: :ready, endpoint: endpoint} when is_binary(endpoint) ->
          Logger.debug("[CloudBackend] Instance ready at #{endpoint}")
          {:ok, endpoint}

        %{availability: :available} ->
          # No instance yet - trigger provisioning
          Logger.info("[CloudBackend] No instance, triggering provisioning...")
          trigger_provisioning_and_wait(ensure_fn, cloud_status_fn, poll_ms, deadline)

        %{availability: :provisioning} ->
          # Already provisioning - wait for it
          Logger.debug("[CloudBackend] Waiting for provisioning...")
          Process.sleep(poll_ms)
          do_wait_for_ready(ensure_fn, cloud_status_fn, poll_ms, deadline)

        %{availability: :unavailable, message: message} ->
          Logger.warning("[CloudBackend] Cloud unavailable: #{message}")
          {:error, {:cloud_unavailable, message}}
      end
    end
  end

  defp trigger_provisioning_and_wait(ensure_fn, cloud_status_fn, poll_ms, deadline) do
    case ensure_fn.() do
      {:ok, endpoint} ->
        {:ok, endpoint}

      {:error, :no_instance} ->
        # Provisioning started, wait for it
        Process.sleep(poll_ms)
        do_wait_for_ready(ensure_fn, cloud_status_fn, poll_ms, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

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
      try do
        # Use short timeout to avoid blocking if InstanceManager is stuck
        case GenServer.call(InstanceManager, :status, 200) do
          %{status: status} -> status
          status when is_atom(status) -> status
          _ -> :none
        end
      catch
        :exit, _ -> :none
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
