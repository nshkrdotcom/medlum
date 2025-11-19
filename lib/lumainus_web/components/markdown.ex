defmodule LumainusWeb.Markdown do
  @moduledoc """
  Lightweight Markdown renderer for LiveView templates.
  """

  use Phoenix.Component

  alias Phoenix.HTML

  attr :content, :string, default: ""
  attr :class, :string, default: nil
  attr :fallback, :string, default: nil

  def markdown(assigns) do
    assigns =
      assigns
      |> assign_new(:content, fn -> "" end)
      |> assign_new(:fallback, fn -> nil end)
      |> assign_new(:class, fn -> nil end)
      |> assign(:rendered, render_markdown(assigns.content, assigns.fallback))

    ~H"""
    <div class={["markdown-body", @class]}>
      {@rendered}
    </div>
    """
  end

  defp render_markdown(nil, fallback), do: render_fallback(fallback)

  defp render_markdown(content, fallback) when is_binary(content) do
    trimmed = String.trim(content)

    if trimmed == "" do
      render_fallback(fallback)
    else
      case Earmark.as_html(trimmed, %Earmark.Options{smartypants: false}) do
        {:ok, html, _} -> HTML.raw(html)
        {:error, html, _} -> HTML.raw(html)
      end
    end
  rescue
    _ -> HTML.raw("")
  end

  defp render_markdown(_, fallback), do: render_fallback(fallback)

  defp render_fallback(nil), do: HTML.raw("")
  defp render_fallback(content), do: HTML.raw(content)
end
