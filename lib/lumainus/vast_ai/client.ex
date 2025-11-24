defmodule Lumainus.VastAI.Client do
  @moduledoc """
  Thin HTTP client for Vast.ai API using Req.
  """

  @base_url "https://console.vast.ai/api/v0"

  def get(path, opts \\ []), do: request(:get, path, nil, opts)
  def post(path, body, opts \\ []), do: request(:post, path, body, opts)
  def put(path, body, opts \\ []), do: request(:put, path, body, opts)
  def delete(path, opts \\ []), do: request(:delete, path, nil, opts)

  defp request(method, path, body, opts) do
    api_key = Keyword.get(opts, :api_key) || fetch_api_key!()
    url = build_url(path, api_key, method)

    headers =
      [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"},
        {"accept", "application/json"}
      ] ++ Keyword.get(opts, :headers, [])

    req_opts = [
      method: method,
      url: url,
      headers: headers,
      body: encode_body(body),
      follow_redirects: true
    ]

    case Req.request(req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_url(path, api_key, method) do
    uri = URI.merge(@base_url, path) |> URI.to_string()

    case method do
      :get ->
        separator = if String.contains?(uri, "?"), do: "&", else: "?"
        uri <> "#{separator}api_key=#{api_key}"

      _ ->
        uri
    end
  end

  defp encode_body(nil), do: ""
  defp encode_body(body) when is_map(body), do: Jason.encode!(body)
  defp encode_body(body), do: body

  defp fetch_api_key! do
    Application.get_env(:lumainus, :vast_ai, [])[:api_key] ||
      System.get_env("VAST_API_KEY") ||
      raise "VAST_API_KEY not configured"
  end
end
