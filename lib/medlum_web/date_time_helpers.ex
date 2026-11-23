defmodule MedlumWeb.DateTimeHelpers do
  @moduledoc false

  alias Medlum.Cldr.DateTime, as: CldrDateTime
  alias Medlum.Cldr.DateTime.Relative, as: CldrDateTimeRelative
  alias Medlum.Cldr.Time, as: CldrTime

  @default_locale "en"
  @default_time_zone "Etc/UTC"

  def format_datetime(value, opts \\ [])
  def format_datetime(value, %{} = opts), do: format_datetime(value, Map.to_list(opts))

  def format_datetime(value, opts) when is_list(opts) do
    locale = opts[:locale] || @default_locale
    time_zone = opts[:timezone] || opts[:time_zone] || @default_time_zone
    format = opts[:format] || :medium

    with {:ok, dt} <- normalize_datetime(value),
         {:ok, shifted} <- DateTime.shift_zone(dt, time_zone),
         {:ok, string} <- CldrDateTime.to_string(shifted, format: format, locale: locale) do
      string
    else
      _ -> fallback_datetime(value)
    end
  end

  def format_relative(value, opts \\ [])
  def format_relative(value, %{} = opts), do: format_relative(value, Map.to_list(opts))

  def format_relative(value, opts) when is_list(opts) do
    locale = opts[:locale] || @default_locale
    time_zone = opts[:timezone] || opts[:time_zone] || @default_time_zone
    relative_to = opts[:relative_to] || DateTime.utc_now()

    with {:ok, dt} <- normalize_datetime(value),
         {:ok, shifted} <- DateTime.shift_zone(dt, time_zone),
         {:ok, relative_base} <- DateTime.shift_zone(relative_to, time_zone),
         {:ok, string} <-
           CldrDateTimeRelative.to_string(shifted,
             relative_to: relative_base,
             locale: locale
           ) do
      string
    else
      _ -> fallback_datetime(value)
    end
  end

  def default_locale, do: @default_locale
  def default_time_zone, do: @default_time_zone

  def format_time(value, opts \\ [])
  def format_time(value, %{} = opts), do: format_time(value, Map.to_list(opts))

  def format_time(value, opts) when is_list(opts) do
    locale = opts[:locale] || @default_locale
    time_zone = opts[:timezone] || opts[:time_zone] || @default_time_zone
    format = opts[:format] || :medium

    with {:ok, dt} <- normalize_datetime(value),
         {:ok, shifted} <- DateTime.shift_zone(dt, time_zone),
         {:ok, string} <- CldrTime.to_string(shifted, format: format, locale: locale) do
      string
    else
      _ -> fallback_datetime(value)
    end
  end

  defp normalize_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp normalize_datetime(%NaiveDateTime{} = ndt),
    do: DateTime.from_naive(ndt, @default_time_zone)

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp normalize_datetime(_), do: :error

  defp fallback_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fallback_datetime(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp fallback_datetime(_), do: nil
end
