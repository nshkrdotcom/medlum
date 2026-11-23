defmodule Medlum.Docling.VastAI.EndpointManager do
  @moduledoc """
  Manages endpoints, DNS, and Cloudflare Tunnel configuration for Vast.ai instances.

  This module handles:
  - DNS record updates (A records for direct IP, CNAME for tunnels)
  - Cloudflare Tunnel detection and management
  - Endpoint recovery and construction
  - IP extraction and validation

  ## DNS Management

  When an instance is provisioned or started, DNS must be updated to point to it.
  Two modes are supported:

  1. **Direct IP (Legacy)** - A record pointing to instance IP
  2. **Cloudflare Tunnel** - CNAME record pointing to tunnel

  The module automatically detects tunnel presence and skips A record updates
  when a tunnel is configured.

  ## Usage

      # Update DNS to point to instance IP
      :ok = EndpointManager.update_dns(ip, instance_id)

      # Build endpoint URL from IP
      "https://docling.example.com" = EndpointManager.build_endpoint(ip)

      # Extract IP from endpoint string
      "1.2.3.4" = EndpointManager.extract_ip("http://1.2.3.4:8044")

      # Check if tunnel is present
      true = EndpointManager.tunnel_present?()

      # Find tunnel ID
      {:ok, "abc123"} = EndpointManager.find_tunnel_id()
  """

  require Logger

  alias Medlum.Cloudflare
  alias Medlum.Cloudflare.Tunnel
  alias Medlum.GPU

  @doc """
  Update Cloudflare DNS A record to point to the given IP address.

  Logs the update to GPU lifecycle events.

  Returns:
  - `:ok` on success
  - `{:error, reason}` on failure
  - `{:error, :invalid_ip}` if IP is invalid

  This function should only be called for non-tunnel instances.
  Tunnel-managed instances use CNAME records set during tunnel setup.
  """
  def update_dns(ip, instance_id) when is_binary(ip) and ip != "" do
    Logger.info("[EndpointManager] Updating DNS for instance #{instance_id} to IP #{ip}")

    case Cloudflare.update_dns_record(ip) do
      {:ok, %{fqdn: fqdn}} ->
        Logger.info("[EndpointManager] DNS updated: #{fqdn} → #{ip}")

        GPU.log(:lifecycle, :dns_updated, "DNS updated for instance",
          instance_id: instance_id,
          ip: ip,
          fqdn: fqdn,
          source: "endpoint_manager"
        )

        :ok

      {:error, reason} ->
        Logger.error("[EndpointManager] Failed to update DNS: #{inspect(reason)}")

        GPU.log_error(:lifecycle, :dns_update_failed, "Failed to update DNS", reason,
          instance_id: instance_id,
          ip: ip,
          source: "endpoint_manager"
        )

        {:error, reason}
    end
  end

  def update_dns(ip, _instance_id) do
    Logger.warning("[EndpointManager] Cannot update DNS - invalid IP: #{inspect(ip)}")
    {:error, :invalid_ip}
  end

  @doc """
  Check if a Cloudflare Tunnel is configured for Vast.ai instances.

  Returns `true` if tunnel exists, `false` otherwise.
  On error, assumes tunnel mode to avoid legacy DNS changes.
  """
  def tunnel_present? do
    case Tunnel.find_by_name("docling-vast") do
      {:ok, [_ | _]} ->
        true

      {:ok, []} ->
        false

      {:error, reason} ->
        Logger.warning(
          "[EndpointManager] Tunnel presence check failed: #{inspect(reason)}; assuming tunnel mode to avoid legacy DNS changes"
        )

        true
    end
  end

  @doc """
  Find the Cloudflare Tunnel ID for Vast.ai instances.

  Returns:
  - `{:ok, tunnel_id}` if tunnel found
  - `{:ok, nil}` if no tunnel exists
  - `{:error, reason}` on API failure
  """
  def find_tunnel_id do
    case Tunnel.find_by_name("docling-vast") do
      {:ok, [%{"id" => tunnel_id} | _]} ->
        Logger.info("[EndpointManager] Found tunnel #{tunnel_id}")
        {:ok, tunnel_id}

      {:ok, []} ->
        Logger.info("[EndpointManager] No tunnel found")
        {:ok, nil}

      {:error, reason} ->
        Logger.warning("[EndpointManager] Tunnel lookup failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Find the Cloudflare Tunnel ID for a stopped instance.

  Used during recovery to determine if instance is tunnel-managed.
  Returns the tunnel ID or `nil` if not found.
  """
  def find_tunnel_id_for_instance do
    case find_tunnel_id() do
      {:ok, tunnel_id} -> tunnel_id
      {:error, _} -> nil
    end
  end

  @doc """
  Build an endpoint URL from an IP address.

  Attempts to use HTTPS via Cloudflare FQDN if configured,
  otherwise falls back to direct HTTP access.

  ## Examples

      iex> build_endpoint("1.2.3.4")
      "https://docling.example.com"  # If FQDN configured

      iex> build_endpoint("1.2.3.4")
      "http://1.2.3.4:8044"  # If no FQDN
  """
  def build_endpoint(ip) when is_binary(ip) do
    fqdn =
      (System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_FQDN") ||
         Cloudflare.cloud_fqdn())
      |> normalize_fqdn()

    if fqdn do
      # Use HTTPS via Cloudflare
      "https://#{fqdn}"
    else
      # Fall back to direct HTTP
      port = Application.get_env(:medlum, :vast_ai_cloud_port, 8044)
      "http://#{ip}:#{port}"
    end
  end

  @doc """
  Extract IP address from an endpoint URL string.

  Returns:
  - IP string if found and valid
  - `nil` if no IP found or invalid

  ## Examples

      iex> extract_ip("http://1.2.3.4:8044")
      "1.2.3.4"

      iex> extract_ip("https://example.com")
      nil
  """
  def extract_ip(endpoint) when is_binary(endpoint) do
    case Regex.run(~r/(\d{1,3}(?:\.\d{1,3}){3})/, endpoint) do
      [_, ip] ->
        case :inet.parse_address(String.to_charlist(ip)) do
          {:ok, _tuple} -> ip
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def extract_ip(_), do: nil

  @doc """
  Recover endpoint URL for an instance given its IP.

  This is used when adopting an existing instance after restart or recovery.
  Delegates to `build_endpoint/1`.
  """
  def recover_endpoint(ip), do: build_endpoint(ip)

  @doc """
  Attempt to recover an existing instance by checking for a tunnel.

  If a tunnel exists, constructs the tunnel-based endpoint.
  Otherwise, returns an error.

  Returns:
  - `{:ok, endpoint, tunnel_id}` on success
  - `{:error, :no_tunnel}` if no tunnel found
  - `{:error, {:tunnel_lookup_failed, reason}}` on API failure

  Used during startup sync and instance recovery.
  """
  def maybe_recover_with_tunnel(instance_id, _ip) do
    case Tunnel.find_by_name("docling-vast") do
      {:ok, [%{"id" => tunnel_id, "name" => tunnel_name} | _]} ->
        Logger.info(
          "[EndpointManager] Found Cloudflare tunnel #{tunnel_name} (#{tunnel_id}); adopting instance #{instance_id} via tunnel"
        )

        endpoint = "https://#{Cloudflare.cloud_fqdn()}"

        GPU.log(:lifecycle, :instance_recovered, "Adopted instance via tunnel",
          instance_id: instance_id,
          endpoint: endpoint,
          tunnel_id: tunnel_id,
          source: "endpoint_manager"
        )

        {:ok, endpoint, tunnel_id}

      {:ok, []} ->
        Logger.warning(
          "[EndpointManager] No Cloudflare tunnel found; cannot adopt instance #{instance_id}"
        )

        {:error, :no_tunnel}

      {:error, reason} ->
        Logger.warning(
          "[EndpointManager] Tunnel lookup failed (#{inspect(reason)}); cannot adopt instance #{instance_id}"
        )

        {:error, {:tunnel_lookup_failed, reason}}
    end
  end

  @doc """
  Cleanup Cloudflare Tunnel for a destroyed instance.

  Returns `:ok` on success or if no tunnel was configured.
  Logs warnings if cleanup fails but doesn't raise errors.
  """
  def cleanup_tunnel(tunnel_id) when is_binary(tunnel_id) do
    Logger.info("[EndpointManager] Cleaning up Cloudflare Tunnel #{tunnel_id}")

    case Tunnel.cleanup_for_vast_ai(tunnel_id) do
      :ok ->
        Logger.info("[EndpointManager] Tunnel #{tunnel_id} cleaned up")
        :ok

      {:error, reason} ->
        Logger.warning("[EndpointManager] Failed to cleanup tunnel: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def cleanup_tunnel(nil), do: :ok

  @doc """
  Persist endpoint URL to database settings.

  Updates the `cloud_url` field in Docling settings for health checks.
  Returns `:ok` regardless of outcome (logs warnings on failure).
  """
  def persist_endpoint(endpoint) when is_binary(endpoint) and endpoint != "" do
    alias Medlum.Docling.Settings, as: DoclingSettings

    case DoclingSettings.update_cloud_url(endpoint) do
      {:ok, _} ->
        Logger.info("[EndpointManager] Updated cloud_url to #{endpoint}")
        :ok

      {:error, reason} ->
        Logger.warning("[EndpointManager] Failed to update cloud_url: #{inspect(reason)}")
        :ok
    end
  end

  def persist_endpoint(_), do: :ok

  @doc """
  Persist endpoint to database only if not already set.

  Used during recovery to ensure database has the endpoint without
  overwriting existing configuration.
  """
  def maybe_persist_endpoint(endpoint) when is_binary(endpoint) and endpoint != "" do
    alias Medlum.Docling.Settings, as: DoclingSettings

    with {:ok, setting} <- DoclingSettings.fetch_or_init() do
      if is_nil(setting.cloud_url) or setting.cloud_url == "" do
        persist_endpoint(endpoint)
      else
        :ok
      end
    else
      _ -> :ok
    end
  end

  def maybe_persist_endpoint(_), do: :ok

  # Private helpers

  defp normalize_fqdn(fqdn) do
    case fqdn do
      nil ->
        nil

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
    end
  end
end
