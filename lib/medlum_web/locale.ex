defmodule MedlumWeb.Locale do
  @moduledoc """
  Sets locale and time zone for requests and LiveViews.
  """
  import Plug.Conn

  alias Medlum.Cldr, as: MedlumCldr

  @default_locale "en"
  @default_time_zone "Etc/UTC"

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = pick_locale(conn)
    time_zone = pick_time_zone(conn)

    Gettext.put_locale(MedlumWeb.Gettext, locale)
    Cldr.put_locale(MedlumCldr, locale)

    conn
    |> assign(:locale, locale)
    |> assign(:timezone, time_zone)
    |> put_session(:locale, locale)
    |> put_session(:timezone, time_zone)
  end

  def on_mount(:set_locale, _params, session, socket) do
    locale = Map.get(session, "locale", @default_locale) |> normalize_locale()
    time_zone = Map.get(session, "timezone", @default_time_zone) |> normalize_time_zone()

    Gettext.put_locale(MedlumWeb.Gettext, locale)
    Cldr.put_locale(MedlumCldr, locale)

    {:cont, Phoenix.Component.assign(socket, locale: locale, timezone: time_zone)}
  end

  def on_mount(_name, _params, _session, socket), do: {:cont, socket}

  defp pick_locale(conn) do
    user_locale(conn) ||
      accept_language_locale(conn) ||
      @default_locale
      |> normalize_locale()
  end

  defp pick_time_zone(conn) do
    user_time_zone(conn) || @default_time_zone |> normalize_time_zone()
  end

  defp user_locale(%Plug.Conn{assigns: %{current_scope: %{user: %{locale: locale}}}})
       when is_binary(locale) and locale != "" do
    locale
  end

  defp user_locale(_), do: nil

  defp user_time_zone(%Plug.Conn{assigns: %{current_scope: %{user: %{timezone: tz}}}})
       when is_binary(tz) and tz != "" do
    tz
  end

  defp user_time_zone(_), do: nil

  defp accept_language_locale(conn) do
    case get_req_header(conn, "accept-language") do
      [header | _] ->
        case Cldr.AcceptLanguage.best_match(header, MedlumCldr) do
          {:ok, tag} -> Cldr.LanguageTag.to_string(tag)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp normalize_locale(locale) when is_binary(locale) do
    case MedlumCldr.validate_locale(locale) do
      {:ok, language_tag} -> Cldr.LanguageTag.to_string(language_tag)
      _ -> @default_locale
    end
  end

  defp normalize_locale(_), do: @default_locale

  defp normalize_time_zone(tz) when is_binary(tz) do
    if tz in Tzdata.zone_list(), do: tz, else: @default_time_zone
  end

  defp normalize_time_zone(_), do: @default_time_zone
end
