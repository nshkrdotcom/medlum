defmodule Medlum.Cloudflare.Tunnel do
  @moduledoc """
  Cloudflare Tunnel management via API.

  Creates and manages Cloudflare Tunnels for Vast.ai instances, enabling
  secure connectivity without exposing ports on the container.

  ## How It Works

  1. Create a tunnel via API → get tunnel ID and token
  2. Pass token to Vast.ai instance as env var
  3. Instance runs `cloudflared` with the token
  4. Cloudflared connects outbound to Cloudflare (no inbound ports needed)
  5. Create CNAME: docling.medlumai.com → <tunnel-id>.cfargotunnel.com

  ## Configuration

      # Environment variables (recommended)
      MEDLUMAI_DOT_COM_CLOUDFLARE_ACCOUNT_ID=<account-id>
      MEDLUMAI_DOT_COM_CLOUDFLARE_ACCOUNT_API_TOKEN=<account-token-with-tunnel-edit>
      MEDLUMAI_DOT_COM_CLOUDFLARE_API_TOKEN=<zone-token-with-dns-edit>
      MEDLUMAI_DOT_COM_CLOUDFLARE_ZONE_ID=<zone-id>

      # Or config
      config :medlum, :cloudflare,
        account_id: "...",
        account_api_token: "...",  # For tunnel operations
        api_token: "...",          # For DNS operations
        zone_id: "..."

  ## Token Permissions Required

  - Account API Token: Cloudflare Tunnel:Edit (account-level)
  - Zone API Token: DNS:Edit (zone-level, for CNAME creation)

  ## Usage

      # Create tunnel for a new Vast.ai instance
      {:ok, tunnel} = Tunnel.create("docling-gpu-123")
      # => %{id: "abc123", token: "eyJ...", name: "docling-gpu-123"}

      # Get the connector install token
      token = tunnel.token
      # Pass to Vast.ai onstart script

      # Create DNS CNAME pointing to tunnel
      {:ok, _} = Tunnel.create_dns_route(tunnel.id, "docling")
      # => docling.medlumai.com → abc123.cfargotunnel.com

      # Delete tunnel when instance is destroyed
      :ok = Tunnel.delete(tunnel.id)
  """

  alias Medlum.ExternalApi

  require Logger

  @base_url "https://api.cloudflare.com/client/v4"
  @default_subdomain "docling"
  @default_domain "medlumai.com"

  # Tunnel configuration for routing traffic to uvicorn
  @default_service_port 8044

  @doc """
  Create a new Cloudflare Tunnel.

  Returns the tunnel ID and connector token needed for cloudflared.

  ## Options

    - `:name` - Tunnel name (default: "docling-<timestamp>")

  ## Returns

      {:ok, %{id: "...", name: "...", token: "..."}}
      {:error, reason}
  """
  def create(name \\ nil) do
    tunnel_name = name || "docling-#{System.system_time(:second)}"

    Logger.info("[Cloudflare.Tunnel] Creating tunnel: #{tunnel_name}")

    with {:ok, account_id} <- get_account_id(),
         {:ok, token} <- get_account_token(),
         {:ok, tunnel} <- create_tunnel(account_id, tunnel_name, token),
         {:ok, connector_token} <- get_tunnel_token(account_id, tunnel["id"], token) do
      result = %{
        id: tunnel["id"],
        name: tunnel["name"],
        token: connector_token,
        cname: "#{tunnel["id"]}.cfargotunnel.com"
      }

      Logger.info("[Cloudflare.Tunnel] Created tunnel #{result.id} (#{result.name})")
      {:ok, result}
    end
  end

  @doc """
  Delete a Cloudflare Tunnel.

  Also cleans up any associated DNS records.
  """
  def delete(tunnel_id) do
    Logger.info("[Cloudflare.Tunnel] Deleting tunnel: #{tunnel_id}")

    with {:ok, account_id} <- get_account_id(),
         {:ok, token} <- get_account_token() do
      # First, try to clean up connections (force delete)
      cleanup_connections(account_id, tunnel_id, token)

      # Then delete the tunnel
      url = "#{@base_url}/accounts/#{account_id}/cfd_tunnel/#{tunnel_id}"

      case ExternalApi.delete(:cloudflare, url, headers: auth_headers(token)) do
        {:ok, %{status: 200, body: %{"success" => true}}} ->
          Logger.info("[Cloudflare.Tunnel] Deleted tunnel #{tunnel_id}")
          :ok

        {:ok, %{status: 404}} ->
          Logger.warning("[Cloudflare.Tunnel] Tunnel #{tunnel_id} not found (already deleted?)")
          :ok

        {:ok, %{body: %{"errors" => errors}}} ->
          {:error, {:cloudflare_error, errors}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Create a DNS CNAME record pointing to the tunnel.

  This makes `<subdomain>.medlumai.com` route through the tunnel.

  ## Options

    - `:subdomain` - Subdomain to create (default: "docling")
    - `:proxied` - Enable Cloudflare proxy/orange cloud (default: true)
  """
  def create_dns_route(tunnel_id, opts \\ []) do
    subdomain = Keyword.get(opts, :subdomain, @default_subdomain)
    domain = config(:domain, @default_domain)
    proxied = Keyword.get(opts, :proxied, true)
    fqdn = "#{subdomain}.#{domain}"
    tunnel_cname = "#{tunnel_id}.cfargotunnel.com"

    Logger.info("[Cloudflare.Tunnel] Creating DNS route: #{fqdn} → #{tunnel_cname}")

    with {:ok, zone_id} <- get_zone_id(),
         {:ok, token} <- get_zone_token(),
         {:ok, record_id} <- upsert_cname_record(zone_id, fqdn, tunnel_cname, proxied, token) do
      Logger.info("[Cloudflare.Tunnel] DNS route created: #{fqdn} (record: #{record_id})")
      {:ok, %{fqdn: fqdn, tunnel_cname: tunnel_cname, record_id: record_id, proxied: proxied}}
    end
  end

  @doc """
  Configure tunnel ingress rules.

  This tells the tunnel how to route incoming traffic to the local service.
  Must be called after tunnel creation and before cloudflared connects.
  """
  def configure_ingress(tunnel_id, opts \\ []) do
    subdomain = Keyword.get(opts, :subdomain, @default_subdomain)
    domain = config(:domain, @default_domain)
    service_port = Keyword.get(opts, :service_port, @default_service_port)
    fqdn = "#{subdomain}.#{domain}"

    Logger.info(
      "[Cloudflare.Tunnel] Configuring ingress for #{tunnel_id}: #{fqdn} → localhost:#{service_port}"
    )

    with {:ok, account_id} <- get_account_id(),
         {:ok, token} <- get_account_token() do
      url = "#{@base_url}/accounts/#{account_id}/cfd_tunnel/#{tunnel_id}/configurations"

      # Ingress rules: route hostname to local service, catch-all returns 404
      config_body = %{
        config: %{
          ingress: [
            %{
              hostname: fqdn,
              service: "http://localhost:#{service_port}"
            },
            %{
              # Catch-all rule (required by Cloudflare)
              service: "http_status:404"
            }
          ]
        }
      }

      case ExternalApi.put(:cloudflare, url, json: config_body, headers: auth_headers(token)) do
        {:ok, %{status: 200, body: %{"success" => true}}} ->
          Logger.info("[Cloudflare.Tunnel] Ingress configured for #{tunnel_id}")
          :ok

        {:ok, %{body: %{"errors" => errors}}} ->
          {:error, {:cloudflare_error, errors}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Get tunnel status and connections.
  """
  def status(tunnel_id) do
    with {:ok, account_id} <- get_account_id(),
         {:ok, token} <- get_account_token() do
      url = "#{@base_url}/accounts/#{account_id}/cfd_tunnel/#{tunnel_id}"

      case ExternalApi.get(:cloudflare, url, headers: auth_headers(token)) do
        {:ok, %{status: 200, body: %{"success" => true, "result" => tunnel}}} ->
          {:ok, tunnel}

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{body: %{"errors" => errors}}} ->
          {:error, {:cloudflare_error, errors}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  List all tunnels for the account.
  """
  def list do
    with {:ok, account_id} <- get_account_id(),
         {:ok, token} <- get_account_token() do
      url = "#{@base_url}/accounts/#{account_id}/cfd_tunnel?is_deleted=false"

      case ExternalApi.get(:cloudflare, url, headers: auth_headers(token)) do
        {:ok, %{status: 200, body: %{"success" => true, "result" => tunnels}}} ->
          {:ok, tunnels}

        {:ok, %{body: %{"errors" => errors}}} ->
          {:error, {:cloudflare_error, errors}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Find existing tunnel by name prefix.

  Useful for finding tunnels created for previous instances.
  """
  def find_by_name(name_prefix) do
    case list() do
      {:ok, tunnels} ->
        matching =
          Enum.filter(tunnels, fn t ->
            String.starts_with?(t["name"] || "", name_prefix)
          end)

        {:ok, matching}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Create tunnel and configure everything needed for Vast.ai.

  This is a convenience function that:
  1. Creates the tunnel
  2. Configures ingress rules
  3. Creates DNS CNAME

  Returns everything needed for the onstart script.
  """
  def provision_for_vast_ai(instance_id, opts \\ []) do
    tunnel_name = "docling-vast-#{instance_id}"
    subdomain = Keyword.get(opts, :subdomain, @default_subdomain)
    service_port = Keyword.get(opts, :service_port, @default_service_port)

    Logger.info("[Cloudflare.Tunnel] Provisioning tunnel for Vast.ai instance #{instance_id}")

    with {:ok, tunnel} <- create(tunnel_name),
         :ok <- configure_ingress(tunnel.id, subdomain: subdomain, service_port: service_port),
         {:ok, dns} <- create_dns_route(tunnel.id, subdomain: subdomain) do
      result = %{
        tunnel_id: tunnel.id,
        tunnel_name: tunnel.name,
        tunnel_token: tunnel.token,
        tunnel_cname: tunnel.cname,
        fqdn: dns.fqdn,
        service_port: service_port
      }

      Logger.info(
        "[Cloudflare.Tunnel] Provisioned tunnel #{tunnel.id} for instance #{instance_id}"
      )

      {:ok, result}
    else
      {:error, reason} = error ->
        Logger.error("[Cloudflare.Tunnel] Failed to provision tunnel: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Clean up tunnel when Vast.ai instance is destroyed.

  Deletes tunnel and removes DNS record.
  """
  def cleanup_for_vast_ai(tunnel_id, opts \\ []) do
    subdomain = Keyword.get(opts, :subdomain, @default_subdomain)

    Logger.info("[Cloudflare.Tunnel] Cleaning up tunnel #{tunnel_id}")

    # Delete DNS record first (optional - tunnel deletion doesn't require this)
    case delete_dns_route(subdomain: subdomain) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Cloudflare.Tunnel] Failed to delete DNS route: #{inspect(reason)}")
    end

    # Delete the tunnel
    delete(tunnel_id)
  end

  @doc """
  Delete DNS CNAME route.
  """
  def delete_dns_route(opts \\ []) do
    subdomain = Keyword.get(opts, :subdomain, @default_subdomain)
    domain = config(:domain, @default_domain)
    fqdn = "#{subdomain}.#{domain}"

    with {:ok, zone_id} <- get_zone_id(),
         {:ok, token} <- get_zone_token(),
         {:ok, records} <- list_dns_records(zone_id, fqdn, "CNAME", token) do
      case records do
        [%{"id" => record_id} | _] ->
          delete_dns_record(zone_id, record_id, token)

        [] ->
          Logger.info("[Cloudflare.Tunnel] No CNAME record found for #{fqdn}")
          :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private - Tunnel API
  # ---------------------------------------------------------------------------

  defp create_tunnel(account_id, name, token) do
    url = "#{@base_url}/accounts/#{account_id}/cfd_tunnel"

    # Generate a random tunnel secret (32 bytes, base64 encoded)
    tunnel_secret = :crypto.strong_rand_bytes(32) |> Base.encode64()

    body = %{
      name: name,
      tunnel_secret: tunnel_secret,
      # Remotely managed
      config_src: "cloudflare"
    }

    case ExternalApi.post(:cloudflare, url, json: body, headers: auth_headers(token)) do
      {:ok, %{status: 200, body: %{"success" => true, "result" => tunnel}}} ->
        {:ok, tunnel}

      {:ok, %{body: %{"errors" => errors}}} ->
        {:error, {:cloudflare_error, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_tunnel_token(account_id, tunnel_id, token) do
    url = "#{@base_url}/accounts/#{account_id}/cfd_tunnel/#{tunnel_id}/token"

    case ExternalApi.get(:cloudflare, url, headers: auth_headers(token)) do
      {:ok, %{status: 200, body: %{"success" => true, "result" => connector_token}}} ->
        {:ok, connector_token}

      {:ok, %{body: %{"errors" => errors}}} ->
        {:error, {:cloudflare_error, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_connections(account_id, tunnel_id, token) do
    # Get active connections and clean them up
    url = "#{@base_url}/accounts/#{account_id}/cfd_tunnel/#{tunnel_id}/connections"

    case ExternalApi.delete(:cloudflare, url, headers: auth_headers(token)) do
      {:ok, %{status: 200}} -> :ok
      # Ignore errors - tunnel might not have connections
      _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private - DNS API
  # ---------------------------------------------------------------------------

  defp upsert_cname_record(zone_id, name, target, proxied, token) do
    case list_dns_records(zone_id, name, "CNAME", token) do
      {:ok, [%{"id" => record_id} | _]} ->
        # Update existing CNAME
        update_dns_record(zone_id, record_id, name, target, "CNAME", proxied, token)

      {:ok, []} ->
        # Delete ALL conflicting A records before creating CNAME
        :ok = purge_a_records(zone_id, name, token)

        # Create new CNAME
        create_dns_record(zone_id, name, target, "CNAME", proxied, token)

      {:error, _} = error ->
        error
    end
  end

  # Delete all A records for a given name to avoid conflicts with CNAME
  defp purge_a_records(zone_id, name, token) do
    case list_dns_records(zone_id, name, "A", token) do
      {:ok, a_records} when is_list(a_records) and length(a_records) > 0 ->
        Logger.info(
          "[Cloudflare.Tunnel] Purging #{length(a_records)} conflicting A record(s) for #{name}"
        )

        Enum.each(a_records, fn %{"id" => record_id, "content" => ip} ->
          Logger.info("[Cloudflare.Tunnel] Deleting A record #{record_id} (#{ip})")

          case delete_dns_record(zone_id, record_id, token) do
            :ok ->
              Logger.info("[Cloudflare.Tunnel] Deleted A record #{record_id}")

            {:error, reason} ->
              Logger.error(
                "[Cloudflare.Tunnel] Failed to delete A record #{record_id}: #{inspect(reason)}"
              )
          end
        end)

        :ok

      {:ok, []} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Cloudflare.Tunnel] Failed to list A records for #{name}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp list_dns_records(zone_id, name, type, token) do
    url = "#{@base_url}/zones/#{zone_id}/dns_records?type=#{type}&name=#{URI.encode(name)}"

    case ExternalApi.get(:cloudflare, url, headers: auth_headers(token)) do
      {:ok, %{status: 200, body: %{"success" => true, "result" => records}}} ->
        {:ok, records}

      {:ok, %{body: %{"errors" => errors}}} ->
        {:error, {:cloudflare_error, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_dns_record(zone_id, name, content, type, proxied, token) do
    url = "#{@base_url}/zones/#{zone_id}/dns_records"

    body = %{
      type: type,
      name: name,
      content: content,
      # Auto TTL when proxied
      ttl: 1,
      proxied: proxied
    }

    case ExternalApi.post(:cloudflare, url, json: body, headers: auth_headers(token)) do
      {:ok, %{status: 200, body: %{"success" => true, "result" => %{"id" => id}}}} ->
        {:ok, id}

      {:ok, %{body: %{"errors" => errors}}} ->
        {:error, {:cloudflare_error, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_dns_record(zone_id, record_id, name, content, type, proxied, token) do
    url = "#{@base_url}/zones/#{zone_id}/dns_records/#{record_id}"

    body = %{
      type: type,
      name: name,
      content: content,
      ttl: 1,
      proxied: proxied
    }

    case ExternalApi.put(:cloudflare, url, json: body, headers: auth_headers(token)) do
      {:ok, %{status: 200, body: %{"success" => true}}} ->
        {:ok, record_id}

      {:ok, %{body: %{"errors" => errors}}} ->
        {:error, {:cloudflare_error, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_dns_record(zone_id, record_id, token) do
    url = "#{@base_url}/zones/#{zone_id}/dns_records/#{record_id}"

    case ExternalApi.delete(:cloudflare, url, headers: auth_headers(token)) do
      {:ok, %{status: 200, body: %{"success" => true}}} ->
        :ok

      {:ok, %{body: %{"errors" => errors}}} ->
        {:error, {:cloudflare_error, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private - Config
  # ---------------------------------------------------------------------------

  defp auth_headers(token) do
    [{"Authorization", "Bearer #{token}"}]
  end

  # Account-level API token for tunnel operations
  # Currently using zone token (needs Tunnel:Edit permission on that token)
  defp get_account_token do
    get_zone_token()
  end

  # Zone-level API token for DNS operations
  defp get_zone_token do
    case config(:api_token) || System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_API_TOKEN") do
      nil -> {:error, :missing_cloudflare_zone_token}
      "" -> {:error, :missing_cloudflare_zone_token}
      token -> {:ok, token}
    end
  end

  defp get_account_id do
    case config(:account_id) || System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_ACCOUNT_ID") do
      nil -> {:error, :missing_cloudflare_account_id}
      "" -> {:error, :missing_cloudflare_account_id}
      id -> {:ok, id}
    end
  end

  defp get_zone_id do
    case config(:zone_id) || System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_ZONE_ID") do
      nil -> {:error, :missing_cloudflare_zone_id}
      "" -> {:error, :missing_cloudflare_zone_id}
      id -> {:ok, id}
    end
  end

  defp config(key, default \\ nil) do
    Application.get_env(:medlum, :cloudflare, [])
    |> Keyword.get(key, default)
  end
end
