defmodule Lumainus.AI.CitationSanitizer do
  @moduledoc """
  Validates and repairs LLM-generated citations for report sections.

  The LLM often produces inconsistent citations with:
  - Missing document_id field
  - Wrong document_reference format (uses filename instead of doc-XXX)
  - Missing line_start, line_end, excerpt fields
  - Inconsistent label formats (e.g., "doc-001:L101" instead of "doc-001")

  This module provides robust validation and automatic repair capabilities
  to ensure all citations meet the required schema.

  ## Example

      document_map = %{
        mock_id_to_doc: %{"doc-001" => %{"id" => "uuid-123", ...}},
        id_to_doc: %{"uuid-123" => %{"id" => "uuid-123", "mock_id" => "doc-001", ...}},
        name_to_doc: %{"report.pdf" => %{"id" => "uuid-123", "mock_id" => "doc-001", ...}}
      }

      citations = [
        %{"label" => "report.pdf", "line_start" => 10}
      ]

      {:ok, sanitized} = CitationSanitizer.sanitize_citations(citations, document_map)
      # Returns cleaned citations with proper doc-XXX format and all required fields
  """

  require Logger

  @type document_map :: %{
          mock_id_to_doc: %{String.t() => map()},
          id_to_doc: %{String.t() => map()},
          name_to_doc: %{String.t() => map()}
        }

  @type citation :: map()
  @type repair_log :: %{
          field: atom(),
          old_value: any(),
          new_value: any(),
          reason: String.t()
        }

  @type sanitize_result ::
          {:ok, list(citation), list(repair_log)}
          | {:error, list({citation, list(String.t())})}

  @doc """
  Sanitizes a list of citations, validating and repairing as needed.

  Returns `{:ok, cleaned_citations, repair_logs}` if all citations can be
  cleaned (either valid or repairable), or `{:error, failed_citations}` if
  any citations cannot be repaired.

  ## Parameters

    - `citations`: List of citation maps from LLM response
    - `document_map`: Map containing document lookup tables by mock_id, UUID, and name

  ## Returns

    - `{:ok, cleaned_citations, repair_logs}`: All citations cleaned successfully
    - `{:error, failed_citations}`: List of tuples with citations and their error messages
  """
  @spec sanitize_citations(list(citation) | nil, document_map) :: sanitize_result
  def sanitize_citations(nil, _document_map), do: {:ok, [], []}
  def sanitize_citations([], _document_map), do: {:ok, [], []}

  def sanitize_citations(citations, document_map) when is_list(citations) do
    results =
      Enum.map(citations, fn citation ->
        sanitize_single_citation(citation, document_map)
      end)

    errors =
      results
      |> Enum.filter(&match?({:error, _, _}, &1))
      |> Enum.map(fn {:error, citation, errors} -> {citation, errors} end)

    if Enum.empty?(errors) do
      cleaned =
        Enum.map(results, fn
          {:ok, citation, _logs} -> citation
          # This shouldn't happen since we filter errors above, but for safety
          {:error, citation, _} -> citation
        end)

      all_logs =
        results
        |> Enum.flat_map(fn
          {:ok, _, logs} -> logs
          {:error, _, _} -> []
        end)

      {:ok, cleaned, all_logs}
    else
      {:error, errors}
    end
  end

  @doc """
  Sanitizes a single citation, attempting to repair common issues.

  Returns `{:ok, citation, repair_logs}` if the citation is valid or was
  successfully repaired, or `{:error, citation, errors}` if validation fails.
  """
  @spec sanitize_single_citation(citation, document_map) ::
          {:ok, citation, list(repair_log)} | {:error, citation, list(String.t())}
  def sanitize_single_citation(citation, document_map) do
    # First attempt to repair the citation
    {repaired_citation, repair_logs} = repair_citation(citation, document_map)

    # Then validate the repaired citation
    case validate_citation(repaired_citation) do
      :ok ->
        {:ok, repaired_citation, repair_logs}

      {:error, errors} ->
        {:error, repaired_citation, errors}
    end
  end

  @doc """
  Validates that a citation has all required fields in the correct format.

  Returns `:ok` if valid, or `{:error, [error_messages]}` if invalid.

  ## Required Fields

    - `label`: Must be in "doc-XXX" format
    - `document_id`: Must be a valid UUID
    - `document_reference`: Must be in "doc-XXX" format
    - `line_start`: Must be a positive integer
    - `line_end`: Must be a positive integer

  ## Optional Fields

    - `excerpt`: String excerpt from the document (defaults to empty string)
  """
  @spec validate_citation(citation) :: :ok | {:error, list(String.t())}
  def validate_citation(citation) when is_map(citation) do
    errors = []

    # Validate label
    errors =
      case validate_label(citation["label"]) do
        :ok -> errors
        {:error, msg} -> [msg | errors]
      end

    # Validate document_id (UUID format)
    errors =
      case validate_uuid(citation["document_id"]) do
        :ok -> errors
        {:error, msg} -> [msg | errors]
      end

    # Validate document_reference
    errors =
      case validate_label(citation["document_reference"]) do
        :ok -> errors
        {:error, msg} -> ["document_reference: #{msg}" | errors]
      end

    # Validate line_start
    errors =
      case validate_positive_integer(citation["line_start"]) do
        :ok -> errors
        {:error, msg} -> ["line_start: #{msg}" | errors]
      end

    # Validate line_end
    errors =
      case validate_positive_integer(citation["line_end"]) do
        :ok -> errors
        {:error, msg} -> ["line_end: #{msg}" | errors]
      end

    # Validate line_end >= line_start
    errors =
      if is_integer(citation["line_start"]) and is_integer(citation["line_end"]) and
           citation["line_end"] < citation["line_start"] do
        ["line_end must be >= line_start" | errors]
      else
        errors
      end

    if Enum.empty?(errors) do
      :ok
    else
      {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Repairs common LLM mistakes in citations.

  This function attempts to fix:
  1. Missing or incorrect document_id
  2. Wrong document_reference format
  3. Label with line suffix (e.g., "doc-001:L101")
  4. Missing line_start/line_end
  5. Missing excerpt

  Returns `{repaired_citation, repair_logs}` where repair_logs track what was changed.
  """
  @spec repair_citation(citation, document_map) :: {citation, list(repair_log)}
  def repair_citation(citation, document_map) when is_map(citation) do
    logs = []

    # Step 1: Normalize and extract label
    {citation, logs} = repair_label(citation, logs)

    # Step 2: Repair document_reference
    {citation, logs} = repair_document_reference(citation, document_map, logs)

    # Step 3: Repair document_id
    {citation, logs} = repair_document_id(citation, document_map, logs)

    # Step 4: Repair line numbers
    {citation, logs} = repair_line_numbers(citation, logs)

    # Step 5: Ensure excerpt exists
    {citation, logs} = repair_excerpt(citation, document_map, logs)

    {citation, Enum.reverse(logs)}
  end

  # === Private Repair Functions ===

  # Repairs the label field, stripping line suffixes like ":L101"
  # Note: If label is a filename/title, it will be repaired in repair_document_reference
  defp repair_label(citation, logs) do
    label = citation["label"]

    cond do
      # Label is nil or empty
      is_nil(label) or label == "" ->
        # Try to infer from document_reference
        if ref = citation["document_reference"] do
          new_label = extract_mock_id(ref)
          log = build_log(:label, label, new_label, "Inferred from document_reference")
          {Map.put(citation, "label", new_label), [log | logs]}
        else
          {citation, logs}
        end

      # Label has line suffix like "doc-001:L101"
      String.contains?(to_string(label), ":") ->
        {base_label, line_hint} = split_label_suffix(label)

        # After stripping suffix, check if it's still valid
        base_label = extract_mock_id(base_label)

        log = build_log(:label, label, base_label, "Stripped line suffix: #{line_hint}")
        citation = Map.put(citation, "label", base_label)

        # Store line hint for potential use in line repair
        citation = Map.put(citation, "__line_hint__", line_hint)
        {citation, [log | logs]}

      # Label is not in doc-XXX format - try to extract doc-XXX pattern
      not String.match?(to_string(label), ~r/^doc-\d{3}$/) ->
        # Try to extract doc-XXX pattern first
        extracted = extract_mock_id(label)

        # If extraction found doc-XXX, use it
        if extracted != label and String.match?(extracted, ~r/^doc-\d{3}$/) do
          log = build_log(:label, label, extracted, "Extracted doc-XXX pattern")
          {Map.put(citation, "label", extracted), [log | logs]}
        else
          # Can't extract doc-XXX from label - mark it for lookup in repair_document_reference
          # We'll leave the label as-is for now and let repair_document_reference handle it
          citation = Map.put(citation, "__needs_label_lookup__", true)
          {citation, logs}
        end

      true ->
        {citation, logs}
    end
  end

  # Repairs document_reference to match doc-XXX format
  # Also repairs label if it was invalid and we found the correct document
  defp repair_document_reference(citation, document_map, logs) do
    reference = citation["document_reference"]
    label = citation["label"]
    needs_label_lookup = citation["__needs_label_lookup__"]

    # If label needs lookup, try that first
    {citation, logs} =
      if needs_label_lookup do
        case find_document_by_reference(label, document_map) do
          {:ok, doc} ->
            mock_id = doc["mock_id"] || doc["label"]
            label_log = build_log(:label, label, mock_id, "Looked up from document map")
            citation = Map.put(citation, "label", mock_id)
            citation = Map.delete(citation, "__needs_label_lookup__")

            # Also update reference if it's not set or invalid
            citation =
              if is_nil(reference) or reference == "" or
                   not String.match?(to_string(reference), ~r/^doc-\d{3}$/) do
                Map.put(citation, "document_reference", mock_id)
              else
                citation
              end

            {citation, [label_log | logs]}

          :not_found ->
            citation = Map.delete(citation, "__needs_label_lookup__")
            {citation, logs}
        end
      else
        {citation, logs}
      end

    # Now process document_reference
    reference = citation["document_reference"]
    label = citation["label"]

    cond do
      # Missing document_reference - use label
      is_nil(reference) or reference == "" ->
        if label && String.match?(to_string(label), ~r/^doc-\d{3}$/) do
          log = build_log(:document_reference, reference, label, "Copied from label")
          {Map.put(citation, "document_reference", label), [log | logs]}
        else
          {citation, logs}
        end

      # Reference is not in doc-XXX format - try to look it up
      not String.match?(to_string(reference), ~r/^doc-\d{3}$/) ->
        case find_document_by_reference(reference, document_map) do
          {:ok, doc} ->
            mock_id = doc["mock_id"] || doc["label"]
            citation = Map.put(citation, "document_reference", mock_id)
            log = build_log(:document_reference, reference, mock_id, "Looked up from document")
            logs = [log | logs]

            # Also repair label if it's invalid
            {citation, logs} =
              if not String.match?(to_string(label), ~r/^doc-\d{3}$/) do
                label_log = build_log(:label, label, mock_id, "Synced with document_reference")
                {Map.put(citation, "label", mock_id), [label_log | logs]}
              else
                {citation, logs}
              end

            {citation, logs}

          :not_found ->
            # Try to extract mock_id pattern
            extracted = extract_mock_id(reference)

            if extracted != reference do
              log =
                build_log(:document_reference, reference, extracted, "Extracted doc-XXX pattern")

              {Map.put(citation, "document_reference", extracted), [log | logs]}
            else
              {citation, logs}
            end
        end

      # Reference doesn't match label - prefer label if valid
      (reference != label and label) && String.match?(to_string(label), ~r/^doc-\d{3}$/) ->
        log = build_log(:document_reference, reference, label, "Matched to label")
        {Map.put(citation, "document_reference", label), [log | logs]}

      true ->
        {citation, logs}
    end
  end

  # Repairs document_id field
  defp repair_document_id(citation, document_map, logs) do
    doc_id = citation["document_id"]
    reference = citation["document_reference"]

    cond do
      # Missing document_id - look it up
      is_nil(doc_id) or doc_id == "" ->
        case find_document_id(citation, document_map) do
          {:ok, found_id} ->
            log = build_log(:document_id, doc_id, found_id, "Looked up from document_reference")
            {Map.put(citation, "document_id", found_id), [log | logs]}

          :not_found ->
            {citation, logs}
        end

      # Invalid UUID format - try to look it up anyway
      not is_valid_uuid?(doc_id) ->
        case find_document_id(citation, document_map) do
          {:ok, found_id} ->
            log = build_log(:document_id, doc_id, found_id, "Replaced invalid UUID")
            {Map.put(citation, "document_id", found_id), [log | logs]}

          :not_found ->
            {citation, logs}
        end

      # Valid UUID but might be wrong - verify it matches reference
      reference && is_valid_uuid?(doc_id) ->
        # Check if the document_id actually corresponds to the reference
        case document_map.id_to_doc[doc_id] do
          %{"mock_id" => ^reference} ->
            # Matches - all good
            {citation, logs}

          %{"mock_id" => different_mock} when different_mock != reference ->
            # Mismatch - prefer reference
            case find_document_id(citation, document_map) do
              {:ok, correct_id} ->
                log =
                  build_log(
                    :document_id,
                    doc_id,
                    correct_id,
                    "Corrected to match document_reference"
                  )

                {Map.put(citation, "document_id", correct_id), [log | logs]}

              :not_found ->
                {citation, logs}
            end

          _ ->
            {citation, logs}
        end

      true ->
        {citation, logs}
    end
  end

  # Repairs line_start and line_end
  defp repair_line_numbers(citation, logs) do
    line_start = citation["line_start"]
    line_end = citation["line_end"]
    line_hint = citation["__line_hint__"]

    {citation, logs} =
      cond do
        # Both missing - try to extract from hint or default to 1
        (is_nil(line_start) or not is_integer(line_start)) and
            (is_nil(line_end) or not is_integer(line_end)) ->
          default_line =
            if line_hint do
              extract_line_number(line_hint)
            else
              1
            end

          citation = Map.put(citation, "line_start", default_line)
          citation = Map.put(citation, "line_end", default_line)
          log = build_log(:line_numbers, nil, default_line, "Defaulted from hint or to 1")
          {citation, [log | logs]}

        # line_start missing but line_end present
        is_nil(line_start) or not is_integer(line_start) ->
          citation = Map.put(citation, "line_start", line_end)
          log = build_log(:line_start, line_start, line_end, "Copied from line_end")
          {citation, [log | logs]}

        # line_end missing but line_start present
        is_nil(line_end) or not is_integer(line_end) ->
          citation = Map.put(citation, "line_end", line_start)
          log = build_log(:line_end, line_end, line_start, "Copied from line_start")
          {citation, [log | logs]}

        true ->
          {citation, logs}
      end

    # Ensure line_end >= line_start
    {citation, logs} =
      if citation["line_end"] < citation["line_start"] do
        swapped_start = citation["line_end"]
        swapped_end = citation["line_start"]
        citation = Map.put(citation, "line_start", swapped_start)
        citation = Map.put(citation, "line_end", swapped_end)
        log = build_log(:line_numbers, nil, nil, "Swapped line_start and line_end")
        {citation, [log | logs]}
      else
        {citation, logs}
      end

    # Clean up temporary hint field
    citation = Map.delete(citation, "__line_hint__")
    {citation, logs}
  end

  # Ensures excerpt field exists
  defp repair_excerpt(citation, _document_map, logs) do
    excerpt = citation["excerpt"]

    if is_nil(excerpt) or excerpt == "" do
      # Default to empty string
      # In the future, could fetch actual content from document
      log = build_log(:excerpt, excerpt, "", "Defaulted to empty string")
      {Map.put(citation, "excerpt", ""), [log | logs]}
    else
      {citation, logs}
    end
  end

  # === Private Validation Functions ===

  defp validate_label(label) when is_binary(label) do
    if String.match?(label, ~r/^doc-\d{3}$/) do
      :ok
    else
      {:error, "label must be in format 'doc-XXX' (e.g., 'doc-001'), got: #{label}"}
    end
  end

  defp validate_label(nil), do: {:error, "label is required"}
  defp validate_label(_), do: {:error, "label must be a string"}

  defp validate_uuid(uuid) when is_binary(uuid) do
    # UUID v4 format: 8-4-4-4-12 hex digits
    uuid_regex = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

    if String.match?(uuid, uuid_regex) do
      :ok
    else
      {:error, "document_id must be a valid UUID, got: #{uuid}"}
    end
  end

  defp validate_uuid(nil), do: {:error, "document_id is required"}
  defp validate_uuid(_), do: {:error, "document_id must be a string UUID"}

  defp validate_positive_integer(n) when is_integer(n) and n > 0, do: :ok
  defp validate_positive_integer(nil), do: {:error, "required"}

  defp validate_positive_integer(n) when is_integer(n),
    do: {:error, "must be positive, got: #{n}"}

  defp validate_positive_integer(_), do: {:error, "must be a positive integer"}

  defp is_valid_uuid?(uuid) when is_binary(uuid) do
    uuid_regex = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    String.match?(uuid, uuid_regex)
  end

  defp is_valid_uuid?(_), do: false

  # === Private Helper Functions ===

  # Splits a label like "doc-001:L101" into {"doc-001", "L101"}
  defp split_label_suffix(label) do
    case String.split(to_string(label), ":", parts: 2) do
      [base, suffix] -> {base, suffix}
      [base] -> {base, nil}
    end
  end

  # Extracts mock_id pattern (doc-XXX) from a string
  defp extract_mock_id(str) when is_binary(str) do
    case Regex.run(~r/(doc-\d{3})/, str) do
      [_, mock_id] -> mock_id
      _ -> normalize_to_mock_id(str)
    end
  end

  defp extract_mock_id(str), do: to_string(str)

  # Attempts to normalize a string to doc-XXX format
  # Only called with binaries from extract_mock_id/1
  defp normalize_to_mock_id(str) do
    # Try to extract any number and format it
    case Regex.run(~r/(\d+)/, str) do
      [_, number_str] ->
        case Integer.parse(number_str) do
          {num, _} when num > 0 and num < 1000 ->
            "doc-#{String.pad_leading(Integer.to_string(num), 3, "0")}"

          _ ->
            "doc-001"
        end

      _ ->
        str
    end
  end

  # Extracts line number from a hint like "L101" or "L001-L005"
  defp extract_line_number(hint) when is_binary(hint) do
    case Regex.run(~r/L(\d+)/, hint) do
      [_, number_str] ->
        case Integer.parse(number_str) do
          {num, _} when num > 0 -> num
          _ -> 1
        end

      _ ->
        1
    end
  end

  defp extract_line_number(_), do: 1

  # Finds a document by reference string (can be mock_id, filename, title, etc.)
  defp find_document_by_reference(reference, document_map) do
    normalized_ref = normalize_reference(reference)

    cond do
      # Try mock_id lookup
      doc = document_map.mock_id_to_doc[reference] ->
        {:ok, doc}

      # Try normalized name lookup
      doc = document_map.name_to_doc[normalized_ref] ->
        {:ok, doc}

      # Try case-insensitive match
      doc = find_by_name_fuzzy(normalized_ref, document_map.name_to_doc) ->
        {:ok, doc}

      true ->
        :not_found
    end
  end

  # Finds document_id from citation using available reference fields
  defp find_document_id(citation, document_map) do
    # Try multiple strategies in order of preference
    strategies = [
      fn -> lookup_by_mock_id(citation["document_reference"], document_map) end,
      fn -> lookup_by_mock_id(citation["label"], document_map) end,
      fn -> lookup_by_id(citation["document_id"], document_map) end,
      fn -> lookup_by_name(citation["document_reference"], document_map) end,
      fn -> lookup_by_name(citation["label"], document_map) end
    ]

    Enum.find_value(strategies, :not_found, fn strategy ->
      case strategy.() do
        {:ok, id} -> {:ok, id}
        _ -> nil
      end
    end)
  end

  defp lookup_by_mock_id(nil, _map), do: :not_found

  defp lookup_by_mock_id(mock_id, document_map) when is_binary(mock_id) do
    case document_map.mock_id_to_doc[mock_id] do
      %{"id" => id} -> {:ok, id}
      _ -> :not_found
    end
  end

  defp lookup_by_mock_id(_, _), do: :not_found

  defp lookup_by_id(nil, _map), do: :not_found

  defp lookup_by_id(doc_id, document_map) when is_binary(doc_id) do
    if document_map.id_to_doc[doc_id] do
      {:ok, doc_id}
    else
      :not_found
    end
  end

  defp lookup_by_id(_, _), do: :not_found

  defp lookup_by_name(nil, _map), do: :not_found

  defp lookup_by_name(name, document_map) when is_binary(name) do
    normalized = normalize_reference(name)

    case document_map.name_to_doc[normalized] do
      %{"id" => id} -> {:ok, id}
      _ -> :not_found
    end
  end

  defp lookup_by_name(_, _), do: :not_found

  # Normalizes a reference for lookup (lowercase, trim)
  defp normalize_reference(ref) when is_binary(ref) do
    ref
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_reference(_), do: ""

  # Fuzzy match by name (case-insensitive)
  defp find_by_name_fuzzy(normalized_ref, name_map) do
    Enum.find_value(name_map, fn {key, doc} ->
      if String.downcase(key) == normalized_ref do
        doc
      else
        nil
      end
    end)
  end

  # Builds a repair log entry
  defp build_log(field, old_value, new_value, reason) do
    %{
      field: field,
      old_value: old_value,
      new_value: new_value,
      reason: reason
    }
  end

  @doc """
  Logs repair information for debugging and monitoring.

  This function should be called after sanitization to track what repairs
  were made to LLM citations.
  """
  def log_repairs(repair_logs, context \\ %{})
  def log_repairs([], _context), do: :ok

  def log_repairs(repair_logs, context) when is_list(repair_logs) do
    section_run_id = context[:section_run_id]
    citation_count = context[:citation_count] || 0

    Logger.info("""
    [CitationSanitizer] Repaired #{length(repair_logs)} citation issues
    Section Run ID: #{section_run_id || "unknown"}
    Total Citations: #{citation_count}
    Repairs:
    #{format_repair_logs(repair_logs)}
    """)
  end

  defp format_repair_logs(logs) do
    logs
    |> Enum.group_by(& &1.field)
    |> Enum.map(fn {field, field_logs} ->
      count = length(field_logs)
      reasons = field_logs |> Enum.map(& &1.reason) |> Enum.uniq() |> Enum.join(", ")
      "  - #{field} (#{count}x): #{reasons}"
    end)
    |> Enum.join("\n")
  end
end
