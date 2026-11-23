defmodule Medlum.VastAI.Client do
  @moduledoc """
  Thin HTTP client for Vast.ai API using Req.

  ## Endpoints Used
  - GET /api/v0/instances/ - list user instances
  - GET /api/v0/instances/{id}/ - get instance details
  - PUT /api/v0/asks/{ask_id}/ - create instance from offer (ask_id = offer["id"])
  - PUT /api/v0/instances/{id}/ - update instance (start/stop/label)
  - DELETE /api/v0/instances/{id}/ - destroy instance
  - POST /api/v0/bundles/ - search offers (JSON body with filters)
  """

  alias Medlum.ExternalApi

  # Use cloud.vast.ai - verified working with curl
  # console.vast.ai redirects to cloud and returns SPA HTML
  @base_url "https://cloud.vast.ai/api/v0"

  def get(path, opts \\ []), do: request(:get, path, nil, opts)
  def post(path, body, opts \\ []), do: request(:post, path, body, opts)
  def put(path, body, opts \\ []), do: request(:put, path, body, opts)
  def delete(path, opts \\ []), do: request(:delete, path, nil, opts)

  defp request(method, path, body, opts) do
    api_key = Keyword.get(opts, :api_key) || fetch_api_key!()
    url = build_url(path, api_key)

    headers =
      [
        {"content-type", "application/json"},
        {"accept", "application/json"}
      ] ++ Keyword.get(opts, :headers, [])

    req_opts = [
      headers: headers,
      body: encode_body(body),
      redirect: false
    ]

    case ExternalApi.request(:vast_ai, method, url, req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        parse_response(body)

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_url(path, api_key) do
    # Build full URL with api_key as query param (works for all methods)
    base = @base_url <> path
    separator = if String.contains?(base, "?"), do: "&", else: "?"
    base <> "#{separator}api_key=#{api_key}"
  end

  defp parse_response(body) when is_map(body), do: {:ok, body}

  defp parse_response(body) when is_binary(body) do
    # Detect HTML responses (SPA redirect issue)
    if String.contains?(body, "<!DOCTYPE") or String.contains?(body, "<html") do
      {:error, :html_response}
    else
      case Jason.decode(body) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _} -> {:error, {:invalid_json, body}}
      end
    end
  end

  defp parse_response(body), do: {:error, {:unexpected_body, body}}

  defp encode_body(nil), do: ""
  defp encode_body(body) when is_map(body), do: Jason.encode!(body)
  defp encode_body(body), do: body

  defp fetch_api_key! do
    Application.get_env(:medlum, :vast_ai, [])[:api_key] ||
      System.get_env("VAST_API_KEY") ||
      raise "VAST_API_KEY not configured"
  end
end
