defmodule MedlumWeb.Admin.Db.BackpexHelpers do
  @moduledoc """
  Shared helpers for Backpex admin views.
  """

  use Phoenix.Component
  import MedlumWeb.DateTimeHelpers

  @doc """
  Returns a render function for datetime fields that respects user timezone.
  """
  def datetime_render do
    fn assigns ->
      timezone = get_timezone(assigns)
      locale = get_locale(assigns)
      formatted = format_datetime(assigns.value, timezone: timezone, locale: locale)

      assigns = Map.put(assigns, :formatted, formatted)

      ~H"<span>{@formatted}</span>"
    end
  end

  defp get_timezone(assigns) do
    # Try to get timezone from various possible locations in assigns
    cond do
      Map.has_key?(assigns, :timezone) ->
        assigns.timezone

      Map.has_key?(assigns, :socket) && Map.has_key?(assigns.socket.assigns, :timezone) ->
        assigns.socket.assigns.timezone

      true ->
        "Etc/UTC"
    end
  end

  defp get_locale(assigns) do
    cond do
      Map.has_key?(assigns, :locale) ->
        assigns.locale

      Map.has_key?(assigns, :socket) && Map.has_key?(assigns.socket.assigns, :locale) ->
        assigns.socket.assigns.locale

      true ->
        "en"
    end
  end
end
