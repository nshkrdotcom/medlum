defmodule Lumainus.Cloudflare do
  @moduledoc """
  Cloudflare DNS management for dynamic Vast.ai instance IPs.

  Requires environment variables:
    - LUMAINUS_DOT_COM_CLOUDFLARE_API_TOKEN: API token with DNS edit permissions
    - LUMAINUS_DOT_COM_CLOUDFLARE_ZONE_ID: Zone ID for lumainus.com

  Or config:
    config :lumainus, :cloudflare,
      api_token: "...",
      zone_id: "...",
      domain: "lumainus.com"

  DNS records are created with 60 second TTL for fast propagation.
  """

  require Logger

  @base_url "https://api.cloudflare.com/client/v4"
  @default_subdomain "docling"
  @default_domain "lumainus.com"

  @doc """
  Update DNS A record to point subdomain to the given IP.

  ## Examples

      # Update docling.lumainus.com to point to 192.168.1.1
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
         {:ok, record_id} <- find_or_create_record(zone_id, fqdn, ip, token) do
      Logger.info("[Cloudflare] Successfully updated #{fqdn} (record: #{record_id})")
      {:ok, %{fqdn: fqdn, ip: ip, record_id: record_id}}
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
    # First, try to find existing record
    case list_dns_records(zone_id, fqdn, token) do
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

  defp list_dns_records(zone_id, name, token) do
    url = "#{@base_url}/zones/#{zone_id}/dns_records?type=A&name=#{URI.encode(name)}"

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
    case config(:api_token) || System.get_env("LUMAINUS_DOT_COM_CLOUDFLARE_API_TOKEN") do
      nil -> {:error, :missing_cloudflare_token}
      token -> {:ok, token}
    end
  end

  defp get_zone_id do
    case config(:zone_id) || System.get_env("LUMAINUS_DOT_COM_CLOUDFLARE_ZONE_ID") do
      nil -> {:error, :missing_cloudflare_zone_id}
      zone_id -> {:ok, zone_id}
    end
  end

  defp config(key, default \\ nil) do
    Application.get_env(:lumainus, :cloudflare, [])
    |> Keyword.get(key, default)
  end
end
