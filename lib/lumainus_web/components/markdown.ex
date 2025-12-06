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
  attr :section_id, :string, default: nil

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
        render_markdown(
          assigns.content,
          assigns.fallback,
          assigns.inline_citations,
          assigns.section_id
        )
      )

    ~H"""
    <div class={["markdown-body", @class]}>
      {@rendered}
    </div>
    """
  end

  defp render_markdown(nil, fallback, _inline_citations, _section_id),
    do: render_fallback(fallback)

  defp render_markdown(content, fallback, inline_citations, section_id) when is_binary(content) do
    trimmed = String.trim(content)

    if trimmed == "" do
      render_fallback(fallback)
    else
      case safe_earmark(trimmed) do
        {:ok, html} ->
          html |> process_provenance_links(inline_citations, section_id) |> HTML.raw()

        :error ->
          trimmed |> process_provenance_links(inline_citations, section_id) |> HTML.raw()
      end
    end
  end

  defp render_markdown(_, fallback, _inline_citations, _section_id), do: render_fallback(fallback)

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

  defp process_provenance_links(html, inline_citations, section_id) do
    citations = build_citation_map(inline_citations)

    html
    |> to_string()
    |> replace_doc_citations(citations, section_id)
    |> replace_reference_citations(citations, section_id)
  end

  defp replace_doc_citations(html, citations, section_id) do
    html
    |> apply_replace(~r/\[(doc-[a-zA-Z0-9_-]+):([^\]]+)\]/, fn _match, doc_ref, label ->
      ref = String.trim(doc_ref)
      render_citation_button(citations, ref, String.trim(label), section_id)
    end)
    |> apply_replace(~r/\[(doc-[a-zA-Z0-9_-]+)\]/, fn _match, doc_ref ->
      ref = String.trim(doc_ref)
      render_citation_button(citations, ref, nil, section_id)
    end)
  end

  defp replace_reference_citations(html, citations, section_id) do
    html
    |> apply_replace(~r/\[([^\[\]:]+):([^\]]+)\]/, fn match, ref, label ->
      cleaned_ref = String.trim(ref)

      if Map.has_key?(citations, cleaned_ref),
        do: render_citation_button(citations, cleaned_ref, String.trim(label), section_id),
        else: match
    end)
    |> apply_replace(~r/\[([^\[\]:]+)\]/, fn match, ref ->
      cleaned_ref = String.trim(ref)

      if Map.has_key?(citations, cleaned_ref),
        do: render_citation_button(citations, cleaned_ref, nil, section_id),
        else: match
    end)
  end

  defp apply_replace(content, regex, fun) do
    Regex.replace(regex, content, fun)
  end

  defp render_citation_button(citations, ref, label, section_id) do
    citation = Map.get(citations, ref) || %{doc_id: ref, label: ref}
    display_label = format_citation_label(citation[:label] || ref)
    doc_id = citation[:doc_id] || ref
    line_start = citation[:line_start]
    line_end = citation[:line_end]

    detail =
      case format_line_range(line_start, line_end) do
        nil -> display_label
        range -> "#{display_label} · #{range}"
      end

    detail = if label, do: "#{detail} #{label}", else: detail

    line_attrs = encode_line_attrs(line_start, line_end, section_id)

    ~s(<button type="button" class="provenance-link" phx-click="open_document_modal" phx-value-doc-id="#{doc_id}"#{line_attrs} title="View source document">📄 #{detail}</button>)
  end

  defp build_citation_map(nil), do: %{}
  defp build_citation_map(entries) when entries == [], do: %{}

  defp build_citation_map(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      ref = citation_value(entry, [:document_reference, :label])
      doc_id = citation_value(entry, [:document_id])
      label = citation_value(entry, [:label, :document_reference])
      line_start = citation_value(entry, [:line_start])
      line_end = citation_value(entry, [:line_end])

      # Strip line hints from ref for map key (e.g., "doc-001:L005-L010" -> "doc-001")
      ref_without_lines = strip_line_hints(ref)

      acc
      |> put_citation(ref_without_lines, doc_id, label, line_start, line_end)
      |> put_citation(ref, doc_id, label, line_start, line_end)
      |> put_citation(label, doc_id, label, line_start, line_end)
    end)
  end

  defp build_citation_map(_), do: %{}

  defp put_citation(acc, ref, doc_id, label, line_start, line_end) do
    if is_nil(ref) do
      acc
    else
      key =
        ref
        |> to_string()
        |> String.trim()

      Map.put_new(acc, key, %{
        doc_id: doc_id && to_string(doc_id),
        label: label && to_string(label),
        line_start: to_int(line_start),
        line_end: to_int(line_end)
      })
    end
  end

  defp citation_value(entry, keys) do
    keys
    |> Enum.map(fn key -> Map.get(entry, key) || Map.get(entry, to_string(key)) end)
    |> Enum.find(& &1)
  end

  # Strip line number hints from document references (e.g., "doc-001:L005-L010" -> "doc-001")
  defp strip_line_hints(nil), do: nil

  defp strip_line_hints(ref) when is_binary(ref) do
    ref
    |> String.replace(~r/:L\d+(-L?\d+)?$/, "")
    |> String.trim()
  end

  defp strip_line_hints(ref), do: ref

  defp to_int(nil), do: nil
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      _ -> nil
    end
  end

  defp to_int(_), do: nil

  defp format_citation_label(nil), do: "?"

  defp format_citation_label(label) do
    label
    |> to_string()
    |> case do
      <<"doc-", rest::binary>> -> strip_leading_zeros(rest)
      <<"id-", rest::binary>> -> strip_leading_zeros(rest)
      other -> other
    end
  end

  defp strip_leading_zeros(rest) do
    case Integer.parse(rest) do
      {num, _} -> Integer.to_string(num)
      _ -> rest
    end
  end

  defp format_line_range(nil, nil), do: nil

  defp format_line_range(start_line, nil) when is_integer(start_line) do
    "L#{pad_line(start_line)}"
  end

  defp format_line_range(nil, end_line) when is_integer(end_line) do
    "L#{pad_line(end_line)}"
  end

  defp format_line_range(start_line, end_line) when start_line == end_line do
    "L#{pad_line(start_line)}"
  end

  defp format_line_range(start_line, end_line) do
    "L#{pad_line(start_line)}-L#{pad_line(end_line)}"
  end

  defp pad_line(line) when is_integer(line) do
    line
    |> Integer.to_string()
    |> String.pad_leading(3, "0")
  end

  defp pad_line(_), do: "000"

  defp encode_line_attrs(nil, _line_end, section_id) do
    encode_section(section_id)
  end

  defp encode_line_attrs(line_start, line_end, section_id) do
    start_attr = ~s( phx-value-line-start="#{line_start}")

    end_attr =
      case line_end || line_start do
        nil -> ""
        value -> ~s( phx-value-line-end="#{value}")
      end

    start_attr <> end_attr <> encode_section(section_id)
  end

  defp encode_section(nil), do: ""
  defp encode_section(section_id), do: ~s( phx-value-section-id="#{section_id}")
end
