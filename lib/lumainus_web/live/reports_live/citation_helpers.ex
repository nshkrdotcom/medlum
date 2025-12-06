defmodule LumainusWeb.ReportsLive.CitationHelpers do
  @moduledoc """
  Citation formatting and processing helpers for ReportsLive.

  This module provides utilities for:
  - Formatting citation data structures
  - Processing inline and persisted citations
  - Aggregating citations by document
  - Parsing and encoding line ranges
  - Formatting citation labels and document button labels
  """

  @doc """
  Formats a citation struct into a simplified map.
  """
  def format_citation(citation) do
    %{
      id: citation.id,
      label: citation.citation_label,
      document_id: citation.document_id,
      line_start: get_in(citation.source_span || %{}, ["line_start"]),
      line_end: get_in(citation.source_span || %{}, ["line_end"])
    }
  end

  @doc """
  Formats inline citations with fallback to persisted citations.
  """
  def format_inline_citations(inline_citations, persisted_citations)

  def format_inline_citations(nil, persisted_citations),
    do: inline_from_persisted(persisted_citations)

  def format_inline_citations(%{"entries" => entries}, persisted_citations)
      when is_list(entries),
      do: format_inline_citations(entries, persisted_citations)

  def format_inline_citations(entries, persisted_citations) when is_list(entries) do
    formatted =
      Enum.map(entries, fn citation ->
        ref =
          citation["document_reference"] || citation[:document_reference] || citation["label"] ||
            citation[:label]

        base_label = citation["label"] || citation[:label]

        doc_id =
          citation["document_id"] ||
            citation[:document_id] ||
            lookup_citation_doc_id(persisted_citations, ref, base_label)

        %{
          document_reference: ref,
          document_id: doc_id,
          label:
            base_label ||
              lookup_citation_label(persisted_citations, ref) ||
              lookup_citation_label(persisted_citations, doc_id),
          line_start: citation["line_start"] || citation[:line_start],
          line_end: citation["line_end"] || citation[:line_end]
        }
      end)

    case formatted do
      [] -> inline_from_persisted(persisted_citations)
      list -> list
    end
  end

  def format_inline_citations(_other, persisted_citations),
    do: inline_from_persisted(persisted_citations)

  @doc """
  Converts persisted citations to inline citation format.
  """
  def inline_from_persisted([]), do: []

  def inline_from_persisted(citations) when is_list(citations) do
    Enum.map(citations, fn citation ->
      source_span = citation.source_span || %{}

      %{
        document_reference: citation.label,
        document_id: citation.document_id,
        label: citation.label,
        line_start: source_span["line_start"],
        line_end: source_span["line_end"]
      }
    end)
  end

  @doc """
  Aggregates inline citations by document, merging overlapping line ranges.
  """
  def aggregate_doc_citations(inline_citations, persisted_citations) do
    labels =
      persisted_citations
      |> Enum.reduce(%{}, fn c, acc -> Map.put_new(acc, c.document_id, c.label) end)

    inline_citations
    |> Enum.group_by(& &1.document_id)
    |> Enum.map(fn {doc_id, entries} ->
      ranges =
        entries
        |> Enum.map(fn c ->
          {
            c[:line_start] || c["line_start"],
            c[:line_end] || c["line_end"] || c[:line_start] || c["line_start"]
          }
        end)
        |> Enum.filter(fn {s, _e} -> is_integer(s) end)
        |> merge_ranges()

      label =
        entries
        |> Enum.find_value(fn c -> c[:label] || c["label"] end) ||
          Map.get(labels, doc_id) || "doc"

      %{
        document_id: doc_id,
        label: label,
        ranges: ranges
      }
    end)
    |> Enum.sort_by(& &1.label)
  end

  @doc """
  Merges overlapping or adjacent line ranges.

  Takes a list of {start, end} tuples and merges any ranges that overlap
  or are adjacent (differ by only 1 line).
  """
  def merge_ranges(ranges) do
    ranges
    |> Enum.map(fn {s, e} -> {s, e || s} end)
    |> Enum.sort()
    |> Enum.reduce([], fn {s, e}, acc ->
      case acc do
        [] ->
          [{s, e}]

        [{ps, pe} | rest] ->
          if s <= pe + 1 do
            [{ps, max(pe, e)} | rest]
          else
            [{s, e} | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Extracts citation documents from a section with formatted labels.
  """
  def section_citation_docs(%{doc_citations: citations}, documents) when is_list(citations) do
    Enum.map(citations, fn cite ->
      doc = find_document_by_id(documents, cite.document_id)
      display_label = format_doc_button_label(doc, cite.label)

      %{
        document_id: cite.document_id,
        label: display_label,
        ranges: cite.ranges || []
      }
    end)
  end

  def section_citation_docs(_, _), do: []

  @doc """
  Looks up a document ID from citations by reference or label.
  """
  def lookup_citation_doc_id(citations, ref, label) do
    Enum.find_value(citations, fn
      %{label: candidate_label, document_id: doc_id}
      when doc_id and (candidate_label == label or candidate_label == ref) ->
        doc_id

      _ ->
        nil
    end)
  end

  @doc """
  Looks up a citation label by reference or ID.
  """
  def lookup_citation_label(citations, ref_or_id) do
    Enum.find_value(citations, fn citation ->
      candidate_label = citation[:label] || citation["label"]
      doc_id = citation[:document_id] || citation["document_id"]

      cond do
        is_nil(ref_or_id) -> nil
        candidate_label && candidate_label == ref_or_id -> candidate_label
        doc_id && doc_id == ref_or_id -> candidate_label
        true -> nil
      end
    end)
  end

  @doc """
  Formats a citation label by stripping prefixes and leading zeros.

  Examples:
    - "doc-001" -> "1"
    - "id-042" -> "42"
    - "custom" -> "custom"
  """
  def format_citation_label(nil), do: "id"

  def format_citation_label(label) do
    label
    |> to_string()
    |> case do
      <<"doc-", rest::binary>> -> strip_leading_zeros(rest)
      <<"id-", rest::binary>> -> strip_leading_zeros(rest)
      other -> other
    end
  end

  @doc """
  Formats a document button label using document metadata.

  Returns a label in the format "number-name" where:
  - number is the document sequence or parsed from mock_id
  - name is the document label, metadata label, filename, or fallback
  """
  def format_doc_button_label(nil, label), do: format_citation_label(label)

  def format_doc_button_label(doc, fallback_label) do
    number =
      doc.sequence ||
        case doc.mock_id do
          <<"doc-", rest::binary>> ->
            case Integer.parse(rest) do
              {num, _} -> num
              _ -> doc.mock_id
            end

          _ ->
            doc.mock_id
        end

    name =
      doc.label ||
        (doc.metadata && doc.metadata["label"]) ||
        doc.filename ||
        fallback_label ||
        "Document"

    "#{number}-#{name}"
  end

  @doc """
  Encodes a list of line ranges into a string format.

  Format: "start1-end1;start2-end2;..."
  Example: [{1, 5}, {10, 15}] -> "1-5;10-15"
  """
  def encode_ranges([]), do: ""

  def encode_ranges(ranges) when is_list(ranges) do
    ranges
    |> Enum.map(fn {s, e} -> "#{s}-#{e}" end)
    |> Enum.join(";")
  end

  @doc """
  Parses a string of line ranges into a list of {start, end} tuples.

  Format: "start1-end1;start2-end2;..."
  Example: "1-5;10-15" -> [{1, 5}, {10, 15}]
  """
  def parse_ranges(nil), do: []
  def parse_ranges(""), do: []

  def parse_ranges(ranges) when is_binary(ranges) do
    ranges
    |> String.split(";", trim: true)
    |> Enum.map(fn part ->
      case String.split(part, "-", parts: 2) do
        [single] ->
          with {s, _} <- Integer.parse(single) do
            {s, s}
          else
            _ -> nil
          end

        [s, e] ->
          with {start, _} <- Integer.parse(s),
               {endv, _} <- Integer.parse(e) do
            {start, max(endv, start)}
          else
            _ -> nil
          end
      end
    end)
    |> Enum.filter(& &1)
  end

  def parse_ranges(_), do: []

  @doc """
  Normalizes line ranges from various input formats.

  Priority:
  1. If ranges_param can be parsed, use those ranges
  2. Otherwise if line_start is provided, create a single range
  3. Otherwise return empty list
  """
  def normalize_ranges(line_start, line_end, ranges_param) do
    parsed = parse_ranges(ranges_param)

    cond do
      parsed != [] ->
        parsed

      is_integer(line_start) ->
        [{line_start, line_end || line_start}]

      true ->
        []
    end
  end

  # Private helper functions

  defp strip_leading_zeros(rest) do
    case Integer.parse(rest) do
      {num, _} -> Integer.to_string(num)
      _ -> rest
    end
  end

  defp find_document_by_id(documents, doc_id) do
    doc_id = to_string(doc_id)

    # First try to find by actual document ID (UUID)
    # Then try to find by sequence number (e.g., "101" for doc-101)
    # Finally try to find by mock_id (e.g., "doc-101")
    Enum.find(documents, &(to_string(&1.id) == doc_id)) ||
      Enum.find(documents, &(to_string(&1.sequence) == doc_id)) ||
      Enum.find(documents, &(&1.mock_id && to_string(&1.mock_id) == doc_id))
  end
end
