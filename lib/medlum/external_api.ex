defmodule Medlum.ExternalApi do
  @moduledoc """
  Wrapper for external API calls with automatic logging and rate limiting.

  All external API calls (Vast.ai, Cloudflare) should go through this module
  for consistent logging and rate limiting.

  ## Usage

      # Direct usage
      ExternalApi.get(:cloudflare, url, headers: [...])
      ExternalApi.post(:vast_ai, url, json: body, headers: [...])

      # Or via request/4
      ExternalApi.request(:cloudflare, :get, url, headers: [...])

  ## Rate Limiting

  Cloudflare API calls include an automatic delay after each request to avoid
  429 rate limit errors. Vast.ai does not require this.
  """

  alias Medlum.ExternalApi.Log
  alias Medlum.Repo

  require Logger

  # Delay after each Cloudflare API call to avoid rate limiting
  @cloudflare_delay_ms 500

  @type service :: :cloudflare | :vast_ai
  @type method :: :get | :post | :put | :delete

  @doc """
  Make an HTTP request with automatic logging and rate limiting.

  Returns the raw Req response.
  """
  @spec request(service(), method(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def request(service, method, url, opts \\ []) do
    start = System.monotonic_time(:millisecond)

    req_opts = Keyword.merge([method: method, url: url], opts)
    result = Req.request(req_opts)

    latency = System.monotonic_time(:millisecond) - start

    log_request(service, method, url, result, latency)

    if service == :cloudflare do
      Process.sleep(@cloudflare_delay_ms)
    end

    result
  end

  @doc "GET request with logging."
  @spec get(service(), String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def get(service, url, opts \\ []), do: request(service, :get, url, opts)

  @doc "POST request with logging."
  @spec post(service(), String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def post(service, url, opts \\ []), do: request(service, :post, url, opts)

  @doc "PUT request with logging."
  @spec put(service(), String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def put(service, url, opts \\ []), do: request(service, :put, url, opts)

  @doc "DELETE request with logging."
  @spec delete(service(), String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def delete(service, url, opts \\ []), do: request(service, :delete, url, opts)

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp log_request(service, method, url, result, latency) do
    {status, error} = extract_status_and_error(result)
    path = extract_path(url)

    Repo.insert!(%Log{
      service: to_string(service),
      method: method |> to_string() |> String.upcase(),
      path: path,
      status: status,
      latency_ms: latency,
      error: error
    })
  rescue
    e ->
      Logger.warning("[ExternalApi] Failed to log request: #{inspect(e)}")
  end

  defp extract_status_and_error({:ok, %{status: status}}), do: {status, nil}
  defp extract_status_and_error({:error, reason}), do: {nil, truncate(inspect(reason), 1000)}

  defp extract_path(url) when is_binary(url) do
    uri = URI.parse(url)
    path = uri.path || "/"

    if uri.query do
      sanitized = sanitize_query(uri.query)
      if sanitized == "", do: path, else: "#{path}?#{sanitized}"
    else
      path
    end
  end

  defp extract_path(_), do: "/"

  # Remove sensitive query params (API keys)
  defp sanitize_query(query) do
    query
    |> URI.decode_query()
    |> Enum.reject(fn {key, _} ->
      key in ["api_key", "apikey", "key", "token", "secret"]
    end)
    |> URI.encode_query()
  end

  defp truncate(str, max) when is_binary(str) and byte_size(str) > max do
    String.slice(str, 0, max) <> "..."
  end

  defp truncate(str, _max), do: str
end
