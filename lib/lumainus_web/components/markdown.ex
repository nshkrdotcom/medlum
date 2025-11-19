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
      try do
        case Earmark.as_html(trimmed, %Earmark.Options{smartypants: false}) do
          {:ok, html, _} -> html |> process_provenance_links() |> HTML.raw()
          {:error, html, _} -> html |> process_provenance_links() |> HTML.raw()
        end
      rescue
        _ -> HTML.raw(trimmed)
      end
    end
  end

  defp render_markdown(_, fallback), do: render_fallback(fallback)

  defp render_fallback(nil), do: HTML.raw("")
  defp render_fallback(content), do: HTML.raw(content)

  defp process_provenance_links(html) when is_binary(html) do
    html
    # Match patterns like [doc-123:L001] or [doc-uuid:label]
    # Captures the full doc-XXX part and the label separately
    |> Regex.replace(
      ~r/\[(doc-[a-zA-Z0-9_-]+):([a-zA-Z0-9_-]+)\]/,
      fn _, doc_ref, label ->
        ~s(<button type="button" class="provenance-link" phx-click="open_document_modal" phx-value-doc-id="#{doc_ref}" title="View source document">📄 #{doc_ref}:#{label}</button>)
      end
    )
    # Match bare references like [doc-123] and turn them into clickable provenance links too
    |> Regex.replace(
      ~r/\[(doc-[a-zA-Z0-9_-]+)\]/,
      fn _, doc_ref ->
        ~s(<button type="button" class="provenance-link" phx-click="open_document_modal" phx-value-doc-id="#{doc_ref}" title="View source document">📄 #{doc_ref}</button>)
      end
    )
  end

  defp process_provenance_links(content), do: content
end
