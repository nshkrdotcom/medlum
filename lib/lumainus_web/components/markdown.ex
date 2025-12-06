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
    # Build queues of citations per label (ordered list, consumed in order)
    citation_queues = build_citation_queues(inline_citations)

    # Use Agent to track mutable state during regex replacement
    {:ok, agent} = Agent.start_link(fn -> citation_queues end)

    result =
      html
      |> to_string()
      |> replace_doc_citations(agent, section_id)
      |> replace_reference_citations(agent, section_id)

    Agent.stop(agent)
    result
  end

  defp replace_doc_citations(html, agent, section_id) do
    # First handle [doc-XXX:label] format
    html =
      Regex.replace(~r/\[(doc-[a-zA-Z0-9_-]+):([^\]]+)\]/, html, fn _match, doc_ref, label ->
        ref = String.trim(doc_ref)
        citation = pop_citation(agent, ref)
        render_citation_button(citation, ref, String.trim(label), section_id)
      end)

    # Then handle [doc-XXX] format
    Regex.replace(~r/\[(doc-[a-zA-Z0-9_-]+)\]/, html, fn _match, doc_ref ->
      ref = String.trim(doc_ref)
      citation = pop_citation(agent, ref)
      render_citation_button(citation, ref, nil, section_id)
    end)
  end

  defp replace_reference_citations(html, agent, section_id) do
    # Handle [ref:label] format
    html =
      Regex.replace(~r/\[([^\[\]:]+):([^\]]+)\]/, html, fn match, ref, label ->
        cleaned_ref = String.trim(ref)

        if has_citations?(agent, cleaned_ref) do
          citation = pop_citation(agent, cleaned_ref)
          render_citation_button(citation, cleaned_ref, String.trim(label), section_id)
        else
          match
        end
      end)

    # Handle [ref] format
    Regex.replace(~r/\[([^\[\]:]+)\]/, html, fn match, ref ->
      cleaned_ref = String.trim(ref)

      if has_citations?(agent, cleaned_ref) do
        citation = pop_citation(agent, cleaned_ref)
        render_citation_button(citation, cleaned_ref, nil, section_id)
      else
        match
      end
    end)
  end

  # Pop the next citation for a given ref from the queue
  defp pop_citation(agent, ref) do
    # Try both the exact ref and the stripped version
    ref_stripped = strip_line_hints(ref)

    Agent.get_and_update(agent, fn queues ->
      # Try exact ref first, then stripped
      {citation, new_queues} =
        case pop_from_queue(queues, ref) do
          {nil, _} -> pop_from_queue(queues, ref_stripped)
          result -> result
        end

      {citation, new_queues}
    end)
  end

  defp pop_from_queue(queues, ref) when is_binary(ref) do
    case Map.get(queues, ref, []) do
      [first | rest] ->
        {first, Map.put(queues, ref, rest)}

      [] ->
        {nil, queues}
    end
  end

  defp pop_from_queue(queues, _ref), do: {nil, queues}

  # Check if there are any citations left for a ref
  defp has_citations?(agent, ref) do
    ref_stripped = strip_line_hints(ref)

    Agent.get(agent, fn queues ->
      case Map.get(queues, ref, []) do
        [_ | _] ->
          true

        [] ->
          case Map.get(queues, ref_stripped, []) do
            [_ | _] -> true
            [] -> false
          end
      end
    end)
  end

  defp render_citation_button(nil, ref, label, section_id) do
    # No citation found - render with just the ref
    display_label = format_citation_label(ref)
    detail = if label, do: "#{display_label} #{label}", else: display_label
    line_attrs = encode_section(section_id)

    ~s(<button type="button" class="provenance-link" phx-click="open_document_modal" phx-value-doc-id="#{ref}"#{line_attrs} title="View source document">📄 #{detail}</button>)
  end

  defp render_citation_button(citation, ref, label, section_id) do
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

  # Build queues of citations per label (preserves order for position-based matching)
  defp build_citation_queues(nil), do: %{}
  defp build_citation_queues(entries) when entries == [], do: %{}

  defp build_citation_queues(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      ref = citation_value(entry, [:document_reference, :label])
      ref_stripped = strip_line_hints(ref)

      citation = %{
        doc_id: citation_value(entry, [:document_id]) |> to_string_safe(),
        label: citation_value(entry, [:label, :document_reference]) |> to_string_safe(),
        line_start: citation_value(entry, [:line_start]) |> to_int(),
        line_end: citation_value(entry, [:line_end]) |> to_int()
      }

      # Add to queue for both exact ref and stripped ref
      acc
      |> append_to_queue(ref, citation)
      |> append_to_queue(ref_stripped, citation)
    end)
  end

  defp build_citation_queues(_), do: %{}

  defp append_to_queue(acc, nil, _citation), do: acc

  defp append_to_queue(acc, ref, citation) when is_binary(ref) do
    key = String.trim(ref)
    Map.update(acc, key, [citation], fn queue -> queue ++ [citation] end)
  end

  defp append_to_queue(acc, _ref, _citation), do: acc

  defp to_string_safe(nil), do: nil
  defp to_string_safe(value), do: to_string(value)

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
