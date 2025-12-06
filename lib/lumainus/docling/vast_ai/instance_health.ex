defmodule Lumainus.Docling.VastAI.InstanceHealth do
  @moduledoc """
  Handles health checking and status monitoring for Vast.ai GPU instances.

  This module is responsible for:
  - Performing periodic health checks via HTTP
  - Tracking health status over time
  - Determining if an instance is healthy and available

  ## Health Check Behavior

  Health checks run periodically when an instance is in `:running` state.
  Results are stored in the instance state and broadcast to subscribers.

  A health check is considered successful if:
  - The HTTP GET request to `/health` returns 200 OK
  - The request completes within the timeout (5 seconds)

  ## Usage

      # Perform a one-time health check
      {:ok, body} = InstanceHealth.check_health(endpoint)

      # Check if instance is currently healthy based on last check
      true = InstanceHealth.healthy?(state)

      # Get health check interval
      30_000 = InstanceHealth.health_check_interval_ms()
  """

  require Logger

  @health_check_interval_ms 30_000

  @doc """
  Returns the interval (in milliseconds) between health checks.
  """
  def health_check_interval_ms, do: @health_check_interval_ms

  @doc """
  Perform an HTTP health check against the given endpoint.

  Returns:
  - `{:ok, body}` if the health check succeeds (HTTP 200)
  - `{:error, reason}` if the check fails

  The health check has a 5-second timeout for both connection and response.
  """
  def check_health(endpoint) when is_binary(endpoint) do
    url = "#{endpoint}/health"

    case Req.get(url, receive_timeout: 5_000, connect_options: [timeout: 5_000]) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  def check_health(_), do: {:error, :no_endpoint}

  @doc """
  Check if the instance is currently healthy based on the last health check.

  Returns `true` if:
  - `healthy` field is `true`
  - `healthy` field is `nil` (not yet checked)

  Returns `false` if the last health check failed.
  """
  def healthy?(%{healthy: false}), do: false
  def healthy?(_), do: true

  @doc """
  Parse a health check result into state fields.

  Returns a map with:
  - `:healthy` - boolean indicating if check passed
  - `:last_health_check` - timestamp of the check
  - `:health_check_error` - error message (if failed) or nil

  ## Examples

      iex> parse_result({:ok, "OK"})
      %{healthy: true, last_health_check: ~U[...], health_check_error: nil}

      iex> parse_result({:error, :timeout})
      %{healthy: false, last_health_check: ~U[...], health_check_error: ":timeout"}
  """
  def parse_result(result) do
    now = DateTime.utc_now()

    {healthy, error} =
      case result do
        {:ok, _} -> {true, nil}
        {:error, reason} -> {false, inspect(reason)}
      end

    %{
      healthy: healthy,
      last_health_check: now,
      health_check_error: error
    }
  end

  @doc """
  Check if health status changed between two states.

  Returns `true` if the `healthy` field differs between old and new state.

  ## Examples

      iex> status_changed?(%{healthy: true}, %{healthy: false})
      true

      iex> status_changed?(%{healthy: true}, %{healthy: true})
      false
  """
  def status_changed?(old_state, new_state) do
    old_state.healthy != new_state.healthy
  end

  @doc """
  Schedule a health check message to be sent after the configured interval.

  Sends `:periodic_health_check` message to the calling process.
  """
  def schedule_check do
    Process.send_after(self(), :periodic_health_check, @health_check_interval_ms)
  end
end
