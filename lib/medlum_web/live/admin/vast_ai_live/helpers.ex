defmodule MedlumWeb.Admin.VastAILive.Helpers do
  @moduledoc """
  Pure helper functions for VastAILive.
  Includes formatting, parsing, and filter utilities.
  """

  # =============================================================================
  # Formatting Functions
  # =============================================================================

  @doc """
  Formats a timestamp for display.
  Returns an empty string if timestamp is nil.
  """
  def format_timestamp(nil, _locale, _timezone), do: ""

  def format_timestamp(%DateTime{} = dt, locale, timezone) do
    format_datetime(dt, locale: locale, timezone: timezone, format: :medium) ||
      dt
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
  end

  @doc """
  Formats location data, handling nil, strings, and lists.
  Returns "Unknown" for empty or nil values.
  """
  def format_location(nil), do: "Unknown"

  def format_location(loc) when is_binary(loc) do
    loc
    |> String.trim()
    |> String.trim_leading(",")
    |> String.trim()
    |> case do
      "" -> "Unknown"
      value -> value
    end
  end

  def format_location(list) when is_list(list) do
    list
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&String.trim/1)
    |> Enum.join(", ")
    |> case do
      "" -> "Unknown"
      value -> value
    end
  end

  def format_location(other), do: to_string(other)

  @doc """
  Formats a price value as a currency string.
  Returns "—" for nil values.
  """
  def format_price(price) do
    case normalize_price(price) do
      nil -> "—"
      num -> "$" <> :erlang.float_to_binary(num, decimals: 3)
    end
  end

  # =============================================================================
  # Price Normalization and Extraction
  # =============================================================================

  @doc """
  Normalizes various price formats to a float value.
  Handles integers, floats, strings, and Decimal values.
  Returns nil for invalid inputs.
  """
  def normalize_price(nil), do: nil
  def normalize_price(val) when is_integer(val), do: val * 1.0
  def normalize_price(val) when is_float(val), do: val

  def normalize_price(val) when is_binary(val) do
    case Float.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  def normalize_price(%Decimal{} = dec), do: Decimal.to_float(dec)
  def normalize_price(_), do: nil

  @doc """
  Extracts GPU price from an offer map.
  Tries multiple possible field names.
  """
  def offer_gpu_price(offer) do
    offer["dph_total_gpu"] ||
      offer["dph_gpu"] ||
      offer["gpu_total_cost"]
  end

  @doc """
  Extracts disk price from an offer map.
  Tries multiple possible field names.
  """
  def offer_disk_price(offer) do
    offer["dph_total_disk"] ||
      offer["dph_disk"] ||
      offer["storage_dph"]
  end

  # =============================================================================
  # Parsing Functions
  # =============================================================================

  @doc """
  Parses an integer from various input types.
  Returns the default value if parsing fails or input is nil/empty.
  """
  def parse_int(nil, default), do: default
  def parse_int("", default), do: default
  def parse_int(val, _default) when is_integer(val), do: val

  def parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  @doc """
  Parses a float from various input types.
  Returns the default value if parsing fails or input is nil/empty.
  """
  def parse_float(nil, default), do: default
  def parse_float("", default), do: default
  def parse_float(val, _default) when is_float(val), do: val

  def parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  @doc """
  Parses geolocation input.
  Returns ["US", "CA"] as default for nil or empty input.
  Handles comma-separated strings and lists.
  """
  def parse_geolocation(nil), do: ["US", "CA"]
  def parse_geolocation(""), do: ["US", "CA"]

  def parse_geolocation(val) when is_binary(val) do
    val |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  def parse_geolocation(val) when is_list(val), do: val

  # =============================================================================
  # String Utilities
  # =============================================================================

  @doc """
  Converts an IP address tuple to a string.
  """
  def tuple_to_ip(tuple) do
    tuple
    |> :inet.ntoa()
    |> to_string()
  end

  @doc """
  Strips trailing dot from a DNS name.
  Returns nil for nil input.
  """
  def strip_trailing_dot(nil), do: nil

  def strip_trailing_dot(value) when is_binary(value) do
    String.replace_suffix(value, ".", "")
  end

  @doc """
  Masks a Cloudflare zone ID for display.
  Shows first 6 and last 4 characters.
  Returns nil for nil or empty input.
  """
  def mask_zone_id(nil), do: nil
  def mask_zone_id(""), do: nil

  def mask_zone_id(zone_id) when is_binary(zone_id) do
    prefix = String.slice(zone_id, 0, 6)
    suffix = String.slice(zone_id, -4, 4)
    "#{prefix}...#{suffix}"
  end

  @doc """
  Normalizes an FQDN by trimming whitespace.
  Returns nil for nil or empty strings.
  """
  def normalize_fqdn(fqdn) do
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

  # =============================================================================
  # Filter Management
  # =============================================================================

  @doc """
  Returns the default filter settings for offer searches.
  """
  def default_filters do
    %{
      gpu_name: "RTX 3090",
      num_gpus: 1,
      max_price: 0.25,
      disk_gb: 16,
      min_ram_gb: 16,
      min_cpu_cores: 4,
      min_inet_down: 100,
      geolocation: ["US", "CA"]
    }
  end

  @doc """
  Builds filter map from URL parameters.
  Uses default values for missing parameters.
  """
  def build_filters_from_params(params) do
    %{
      gpu_name: params["gpu_name"] || "RTX 3090",
      num_gpus: parse_int(params["num_gpus"], 1),
      max_price: parse_float(params["max_price"], 0.25),
      disk_gb: parse_int(params["disk_gb"], 16),
      min_ram_gb: parse_int(params["min_ram_gb"], 16),
      min_cpu_cores: parse_int(params["min_cpu_cores"], 4),
      min_inet_down: parse_int(params["min_inet_down"], 100),
      geolocation: parse_geolocation(params["geolocation"])
    }
  end

  # =============================================================================
  # Instance Checks
  # =============================================================================

  @doc """
  Checks if any instances are in an active state (running or loading).
  """
  def has_active_instances?(instances) do
    Enum.any?(instances, &(&1["actual_status"] in ["running", "loading"]))
  end

  # =============================================================================
  # Private Helper for format_timestamp
  # =============================================================================

  # Note: format_datetime/1 is expected to be available via Phoenix helpers
  # or needs to be delegated from the calling context
  defp format_datetime(_dt, _opts) do
    # This function is typically provided by Phoenix.HTML or similar
    # If not available, we fall back to ISO8601 format in format_timestamp/3
    nil
  end
end
