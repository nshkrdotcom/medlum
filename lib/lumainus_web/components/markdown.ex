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
      case safe_earmark(trimmed) do
        {:ok, html} ->
          html |> process_provenance_links() |> HTML.raw()

        :error ->
          trimmed |> process_provenance_links() |> HTML.raw()
      end
    end
  end

  defp render_markdown(_, fallback), do: render_fallback(fallback)

  defp safe_earmark(text) do
    try do
      case Earmark.as_html(text) do
        {:ok, html, _} -> {:ok, html}
        {:error, html, _} -> {:ok, html}
      end
    rescue
      _ -> :error
    end
  end

  defp render_fallback(nil), do: HTML.raw("")
  defp render_fallback(content), do: HTML.raw(content)

  defp process_provenance_links(html) when is_binary(html) do
    html =
      Regex.replace(
        ~r/\[(doc-[a-zA-Z0-9_-]+):([^\]]+)\]/,
        html,
        fn _match, doc_ref, label ->
          ~s(<button type="button" class="provenance-link" phx-click="open_document_modal" phx-value-doc-id="#{doc_ref}" title="View source document">📄 #{doc_ref}:#{label}</button>)
        end
      )

    Regex.replace(
      ~r/\[(doc-[a-zA-Z0-9_-]+)\]/,
      html,
      fn _match, doc_ref ->
        ~s(<button type="button" class="provenance-link" phx-click="open_document_modal" phx-value-doc-id="#{doc_ref}" title="View source document">📄 #{doc_ref}</button>)
      end
    )
  end
end
