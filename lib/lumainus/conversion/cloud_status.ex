defmodule Lumainus.Conversion.CloudStatus do
  @moduledoc """
  Single source of truth for cloud backend availability.

  Wraps InstanceManager status for use by both legacy and v2 conversion systems.
  This eliminates the disconnect between VastAI admin UI showing "healthy" while
  the conversion BackendRouter sees "unavailable".

  ## Availability States

  - `:ready` — Instance running and healthy, immediate processing
  - `:available` — No instance but can provision on-demand
  - `:provisioning` — Instance currently starting up
  - `:unavailable` — Cannot accept jobs (disabled, error, etc.)

  ## Usage

      # Check if cloud can accept jobs
      case CloudStatus.get() do
        %{can_accept_jobs: true, availability: :ready} ->
          # Process immediately
        %{can_accept_jobs: true, availability: :available} ->
          # Will provision on first use
        %{can_accept_jobs: true, availability: :provisioning} ->
          # Job will wait for instance
        %{can_accept_jobs: false} ->
          # Reject with clear error
      end
  """

  alias Lumainus.Docling.VastAI.InstanceManager
  alias Lumainus.Docling.Settings

  require Logger

  @type availability :: :ready | :available | :provisioning | :unavailable

  @type t :: %{
          availability: availability(),
          endpoint: String.t() | nil,
          message: String.t(),
          detail: String.t() | nil,
          can_accept_jobs: boolean(),
          instance_info: map() | nil
        }

  @doc """
  Get current cloud backend status.

  Returns a map with availability state, endpoint (if available),
  user-friendly message, and whether jobs can be accepted.
  """
  @spec get() :: t()
  def get do
    get(instance_manager: InstanceManager)
  end

  @doc """
  Get cloud status with injectable dependencies (for testing).
  """
  @spec get(keyword()) :: t()
  def get(opts) do
    instance_manager = Keyword.get(opts, :instance_manager, InstanceManager)

    if process_alive?(instance_manager) do
      status = get_instance_status(instance_manager)
      build_status_from_instance(status, instance_manager)
    else
      # InstanceManager not running - check if cloud is even configured
      if cloud_configured?() do
        %{
          availability: :unavailable,
          endpoint: nil,
          message: "Cloud service not running",
          detail: "InstanceManager process is not available",
          can_accept_jobs: false,
          instance_info: nil
        }
      else
        %{
          availability: :unavailable,
          endpoint: nil,
          message: "Cloud GPU not configured",
          detail: "No Vast.ai API key configured",
          can_accept_jobs: false,
          instance_info: nil
        }
      end
    end
  end

  @doc """
  Check if cloud backend can currently accept jobs.
  """
  @spec can_accept_jobs?() :: boolean()
  def can_accept_jobs? do
    get().can_accept_jobs
  end

  @doc """
  Check if cloud is ready for immediate processing (no provisioning wait).
  """
  @spec ready?() :: boolean()
  def ready? do
    get().availability == :ready
  end

  @doc """
  Get the cloud endpoint if available.
  """
  @spec endpoint() :: {:ok, String.t()} | {:error, :no_endpoint}
  def endpoint do
    case get() do
      %{endpoint: endpoint} when is_binary(endpoint) and endpoint != "" ->
        {:ok, endpoint}

      _ ->
        {:error, :no_endpoint}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp build_status_from_instance(status, instance_manager) do
    endpoint = get_endpoint_safe(instance_manager)

    case status do
      %{status: :running, healthy: true} = info ->
        maybe_autofix_cloud_url(endpoint)

        %{
          availability: :ready,
          endpoint: endpoint,
          message: "Cloud GPU ready",
          detail: format_instance_detail(info),
          can_accept_jobs: true,
          instance_info: info
        }

      %{status: :running, healthy: nil} = info ->
        detail = info[:health_check_error] || "Instance running, waiting for first health check"

        %{
          availability: :provisioning,
          endpoint: endpoint,
          message: "Cloud GPU starting up",
          detail: detail,
          can_accept_jobs: true,
          instance_info: info
        }

      %{status: :running, healthy: false} = info ->
        detail = info[:health_check_error] || "Instance running, waiting for health check"

        %{
          availability: :provisioning,
          endpoint: endpoint,
          message: "Cloud GPU starting up",
          detail: detail,
          can_accept_jobs: true,
          instance_info: info
        }

      %{status: :loading} = info ->
        %{
          availability: :provisioning,
          endpoint: nil,
          message: "Cloud GPU provisioning",
          detail: "Vast.ai instance being created (~3-5 min)",
          can_accept_jobs: true,
          instance_info: info
        }

      %{status: :none} ->
        if cloud_enabled?() do
          %{
            availability: :unavailable,
            endpoint: nil,
            message: "Cloud GPU not provisioned",
            detail: "Provisioning is admin-only right now",
            can_accept_jobs: false,
            instance_info: nil
          }
        else
          %{
            availability: :unavailable,
            endpoint: nil,
            message: "Cloud GPU disabled",
            detail: "Enable in admin settings",
            can_accept_jobs: false,
            instance_info: nil
          }
        end

      %{status: :error, error: error} = info ->
        %{
          availability: :unavailable,
          endpoint: nil,
          message: "Cloud GPU error",
          detail: format_error(error),
          can_accept_jobs: false,
          instance_info: info
        }

      %{status: :stopped} = info ->
        %{
          availability: :available,
          endpoint: nil,
          message: "Cloud GPU stopped",
          detail: "Instance will start on first use",
          can_accept_jobs: true,
          instance_info: info
        }

      other ->
        Logger.warning("[CloudStatus] Unexpected instance status: #{inspect(other)}")

        %{
          availability: :unavailable,
          endpoint: nil,
          message: "Cloud GPU unavailable",
          detail: other[:message] || "Unknown status",
          can_accept_jobs: false,
          instance_info: other
        }
    end
  end

  defp get_instance_status(instance_manager) do
    try do
      GenServer.call(instance_manager, :status, 1_000)
    catch
      :exit, {:timeout, _} ->
        Logger.warning("[CloudStatus] InstanceManager timeout")
        %{status: :error, error: :timeout}

      :exit, reason ->
        Logger.warning("[CloudStatus] InstanceManager error: #{inspect(reason)}")
        %{status: :error, error: reason}
    end
  end

  defp get_endpoint_safe(instance_manager) do
    try do
      case GenServer.call(instance_manager, :get_endpoint, 1_000) do
        {:ok, endpoint} -> endpoint
        _ -> nil
      end
    catch
      :exit, _ -> nil
    end
  end

  defp cloud_configured? do
    case Application.get_env(:lumainus, :vast_ai, []) do
      config when is_list(config) ->
        api_key = Keyword.get(config, :api_key)
        is_binary(api_key) and api_key != ""

      _ ->
        false
    end
  end

  defp cloud_enabled? do
    if cloud_configured?() do
      # Check if cloud backend is enabled in settings
      {:ok, settings} = Settings.fetch_or_init()

      # Cloud is enabled if it's in the profile backends or explicitly enabled
      profiles = settings.v2_profile_backends || %{}
      enhanced_backends = Map.get(profiles, "enhanced", [])
      "cloud" in enhanced_backends
    else
      false
    end
  end

  defp format_instance_detail(%{instance_id: id, cost_per_hour: cost}) when not is_nil(cost) do
    "Instance ##{id} | $#{format_cost(cost)}/hr"
  end

  defp format_instance_detail(%{instance_id: id}) do
    "Instance ##{id}"
  end

  defp format_instance_detail(_), do: nil

  defp format_cost(cost) when is_float(cost), do: :erlang.float_to_binary(cost, decimals: 2)
  defp format_cost(cost), do: to_string(cost)

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  defp process_alive?(module) do
    case Process.whereis(module) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp maybe_autofix_cloud_url(endpoint) when is_binary(endpoint) and endpoint != "" do
    with {:ok, setting} <- Settings.fetch_or_init(),
         true <- is_nil(setting.cloud_url) or setting.cloud_url == "" do
      Logger.warning(
        "[CloudStatus] Cloud endpoint ready but cloud_url is missing; persisting #{endpoint}"
      )

      case Settings.update_settings(%{cloud_url: endpoint}) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[CloudStatus] Failed to persist missing cloud_url #{endpoint}: #{inspect(reason)}"
          )
      end
    else
      _ ->
        :ok
    end
  end

  defp maybe_autofix_cloud_url(_), do: :ok
end
