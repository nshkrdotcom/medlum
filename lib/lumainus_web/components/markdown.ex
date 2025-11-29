defmodule LumainusWeb.Markdown do
  @moduledoc """
  Lightweight Markdown renderer for LiveView templates.
  """

  use Phoenix.Component

  alias Phoenix.HTML

  attr :content, :string, default: ""
  attr :class, :string, default: nil
  attr :fallback, :string, default: nil
  attr :inline_citations, :list, default: []

  def markdown(assigns) do
    assigns =
      assigns
      |> assign_new(:content, fn -> "" end)
      |> assign_new(:fallback, fn -> nil end)
      |> assign_new(:class, fn -> nil end)
      |> assign_new(:inline_citations, fn -> [] end)

    assigns =
      assign(
        assigns,
        :rendered,
        render_markdown(assigns.content, assigns.fallback, assigns.inline_citations)
      )

    ~H"""
    <div class={["markdown-body", @class]}>
      {@rendered}
    </div>
    """
  end

  defp render_markdown(nil, fallback, _inline_citations), do: render_fallback(fallback)

  defp render_markdown(content, fallback, inline_citations) when is_binary(content) do
    trimmed = String.trim(content)

    if trimmed == "" do
      render_fallback(fallback)
    else
      case safe_earmark(trimmed) do
        {:ok, html} ->
          html |> process_provenance_links(inline_citations) |> HTML.raw()

        :error ->
          trimmed |> process_provenance_links(inline_citations) |> HTML.raw()
      end
    end
  end

  defp render_markdown(_, fallback, _inline_citations), do: render_fallback(fallback)

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

  defp process_provenance_links(html, inline_citations) do
    citations = build_citation_map(inline_citations)

    html
    |> to_string()
    |> replace_doc_citations(citations)
    |> replace_reference_citations(citations)
  end

  defp replace_doc_citations(html, citations) do
    html
    |> apply_replace(~r/\[(doc-[a-zA-Z0-9_-]+):([^\]]+)\]/, fn _match, doc_ref, label ->
      ref = String.trim(doc_ref)
      render_citation_button(citations, ref, String.trim(label))
    end)
    |> apply_replace(~r/\[(doc-[a-zA-Z0-9_-]+)\]/, fn _match, doc_ref ->
      ref = String.trim(doc_ref)
      render_citation_button(citations, ref, nil)
    end)
  end

  defp replace_reference_citations(html, citations) do
    html
    |> apply_replace(~r/\[([^\[\]:]+):([^\]]+)\]/, fn match, ref, label ->
      cleaned_ref = String.trim(ref)

      if Map.has_key?(citations, cleaned_ref),
        do: render_citation_button(citations, cleaned_ref, String.trim(label)),
        else: match
    end)
    |> apply_replace(~r/\[([^\[\]:]+)\]/, fn match, ref ->
      cleaned_ref = String.trim(ref)

      if Map.has_key?(citations, cleaned_ref),
        do: render_citation_button(citations, cleaned_ref, nil),
        else: match
    end)
  end

  defp apply_replace(content, regex, fun) do
    Regex.replace(regex, content, fun)
  end

  defp render_citation_button(citations, ref, label) do
    citation = Map.get(citations, ref) || %{doc_id: ref, label: ref}
    display_label = citation[:label] || ref
    doc_id = citation[:doc_id] || ref
    detail = if label, do: "#{display_label}:#{label}", else: display_label

    ~s(<button type="button" class="provenance-link" phx-click="open_document_modal" phx-value-doc-id="#{doc_id}" title="View source document">📄 #{detail}</button>)
  end

  defp build_citation_map(nil), do: %{}
  defp build_citation_map(entries) when entries == [], do: %{}

  defp build_citation_map(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      ref = citation_value(entry, [:document_reference, :label])
      doc_id = citation_value(entry, [:document_id])
      label = citation_value(entry, [:label, :document_reference])

      acc
      |> put_citation(ref, doc_id, label)
      |> put_citation(label, doc_id, label)
    end)
  end

  defp build_citation_map(_), do: %{}

  defp put_citation(acc, ref, doc_id, label) do
    if is_nil(ref) do
      acc
    else
      key =
        ref
        |> to_string()
        |> String.trim()

      Map.put_new(acc, key, %{
        doc_id: doc_id && to_string(doc_id),
        label: label && to_string(label)
      })
    end
  end

  defp citation_value(entry, keys) do
    keys
    |> Enum.map(fn key -> Map.get(entry, key) || Map.get(entry, to_string(key)) end)
    |> Enum.find(& &1)
  end
end
