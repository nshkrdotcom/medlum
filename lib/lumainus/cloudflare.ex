defmodule Lumainus.Cloudflare do
  @moduledoc """
  Cloudflare DNS management for dynamic Vast.ai instance IPs.

  Requires environment variables:
    - MEDLUMAI_DOT_COM_CLOUDFLARE_API_TOKEN: API token with DNS edit permissions
    - MEDLUMAI_DOT_COM_CLOUDFLARE_ZONE_ID: Zone ID for medlumai.com

  Or config:
    config :lumainus, :cloudflare,
      api_token: "...",
      zone_id: "...",
      domain: "medlumai.com"

  DNS records are created with 60 second TTL for fast propagation.
  """

  require Logger

  @base_url "https://api.cloudflare.com/client/v4"
  @default_subdomain "docling"
  @default_domain "medlumai.com"

  @doc """
  Update DNS A record to point subdomain to the given IP.

  ## Examples

      # Update docling.medlumai.com to point to 192.168.1.1
      Cloudflare.update_dns_record("192.168.1.1")

      # Update custom subdomain
      Cloudflare.update_dns_record("192.168.1.1", subdomain: "gpu")
  """
  def update_dns_record(ip, opts \\ []) do
    subdomain = Keyword.get(opts, :subdomain, @default_subdomain)
    domain = config(:domain, @default_domain)
    fqdn = "#{subdomain}.#{domain}"

    Logger.info("[Cloudflare] Updating #{fqdn} → #{ip}")

    with {:ok, token} <- get_token(),
         {:ok, zone_id} <- get_zone_id(),
         {:ok, result} <- find_or_create_record(zone_id, fqdn, ip, token) do
      case result do
        %{skipped: :cname_exists} ->
          # CNAME already exists - tunnel mode active, no A record needed
          {:ok, %{fqdn: fqdn, ip: ip, skipped: :cname_exists}}

        record_id when is_binary(record_id) ->
          Logger.info("[Cloudflare] Successfully updated #{fqdn} (record: #{record_id})")
          {:ok, %{fqdn: fqdn, ip: ip, record_id: record_id}}
      end
    end
  end

  @doc """
  Get the configured FQDN for the cloud backend.
  """
  def cloud_fqdn(opts \\ []) do
    subdomain = Keyword.get(opts, :subdomain, @default_subdomain)
    domain = config(:domain, @default_domain)
    "#{subdomain}.#{domain}"
  end

  @doc """
  Get the full HTTPS URL for the cloud backend.
  """
  def cloud_url(opts \\ []) do
    "https://#{cloud_fqdn(opts)}"
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp find_or_create_record(zone_id, fqdn, ip, token) do
    # First, check if a CNAME already exists (tunnel mode)
    case check_cname_exists(zone_id, fqdn, token) do
      {:ok, true} ->
        Logger.info(
          "[Cloudflare] CNAME already exists for #{fqdn} - skipping A record (tunnel mode active)"
        )

        {:ok, %{fqdn: fqdn, skipped: :cname_exists}}

      {:ok, false} ->
        # No CNAME - proceed with A record
        do_find_or_create_a_record(zone_id, fqdn, ip, token)

      {:error, _} ->
        # If CNAME check fails, try to proceed anyway
        Logger.warning("[Cloudflare] CNAME check failed, attempting A record anyway")
        do_find_or_create_a_record(zone_id, fqdn, ip, token)
    end
  end

  defp do_find_or_create_a_record(zone_id, fqdn, ip, token) do
    # Try to find existing A record
    case list_dns_records(zone_id, fqdn, "A", token) do
      {:ok, [%{"id" => record_id} | _]} ->
        # Update existing record
        update_record(zone_id, record_id, fqdn, ip, token)

      {:ok, []} ->
        # Create new record
        create_record(zone_id, fqdn, ip, token)

      {:error, _} = error ->
        error
    end
  end

  defp check_cname_exists(zone_id, name, token) do
    case list_dns_records(zone_id, name, "CNAME", token) do
      {:ok, [_ | _]} -> {:ok, true}
      {:ok, []} -> {:ok, false}
      {:error, _} = error -> error
    end
  end

  defp list_dns_records(zone_id, name, type, token) do
    url = "#{@base_url}/zones/#{zone_id}/dns_records?type=#{type}&name=#{URI.encode(name)}"

    case Req.get(url, headers: auth_headers(token)) do
      {:ok, %{status: 200, body: %{"success" => true, "result" => records}}} ->
        {:ok, records}

      {:ok, %{body: %{"errors" => errors}}} ->
        {:error, {:cloudflare_error, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_record(zone_id, name, ip, token) do
    url = "#{@base_url}/zones/#{zone_id}/dns_records"

    body = %{
      type: "A",
      name: name,
      content: ip,
      ttl: 60,
      proxied: false
    }

    case Req.post(url, json: body, headers: auth_headers(token)) do
      {:ok, %{status: 200, body: %{"success" => true, "result" => %{"id" => id}}}} ->
        {:ok, id}

      {:ok, %{body: %{"errors" => errors}}} ->
        {:error, {:cloudflare_error, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_record(zone_id, record_id, name, ip, token) do
    url = "#{@base_url}/zones/#{zone_id}/dns_records/#{record_id}"

    body = %{
      type: "A",
      name: name,
      content: ip,
      ttl: 60,
      proxied: false
    }

    case Req.put(url, json: body, headers: auth_headers(token)) do
      {:ok, %{status: 200, body: %{"success" => true}}} ->
        {:ok, record_id}

      {:ok, %{body: %{"errors" => errors}}} ->
        {:error, {:cloudflare_error, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auth_headers(token) do
    [{"Authorization", "Bearer #{token}"}]
  end

  defp get_token do
    case config(:api_token) || System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_API_TOKEN") do
      nil -> {:error, :missing_cloudflare_token}
      token -> {:ok, token}
    end
  end

  defp get_zone_id do
    case config(:zone_id) || System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_ZONE_ID") do
      nil -> {:error, :missing_cloudflare_zone_id}
      zone_id -> {:ok, zone_id}
    end
  end

  defp config(key, default \\ nil) do
    Application.get_env(:lumainus, :cloudflare, [])
    |> Keyword.get(key, default)
  end
end
