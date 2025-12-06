# Citation Sanitizer Implementation

## Overview

The `CitationSanitizer` module provides robust validation and automatic repair of LLM-generated citations for the Lumainus reports system. It addresses common inconsistencies in citations returned by LLMs when generating medical reports.

## Problem Statement

LLMs often produce inconsistent citations with various issues:
- **Missing document_id field** - Citations lack the required UUID
- **Wrong document_reference format** - Uses filename (e.g., "report.pdf") instead of mock_id (e.g., "doc-001")
- **Missing line fields** - Citations lack line_start, line_end, or excerpt
- **Inconsistent label formats** - Labels have suffixes like "doc-001:L101" or use filenames
- **Mismatched fields** - document_id doesn't correspond to document_reference

## Solution

The CitationSanitizer provides a multi-stage repair pipeline:

### 1. Citation Structure Validation

Validates that each citation has required fields:
- `label`: Must be in "doc-XXX" format (e.g., "doc-001", "doc-002")
- `document_id`: Must be a valid UUID v4
- `document_reference`: Must be in "doc-XXX" format matching label
- `line_start`: Must be a positive integer
- `line_end`: Must be a positive integer >= line_start
- `excerpt`: Optional string (defaults to empty)

### 2. Automatic Repair

The sanitizer automatically repairs common LLM mistakes:

#### Label Repair
- Strips line suffixes: `"doc-001:L101"` → `"doc-001"` (extracts line 101 for line_start)
- Extracts mock_id pattern: `"from doc-002 section"` → `"doc-002"`
- Looks up filenames: `"ekg_report.pdf"` → `"doc-001"` (via document map)

#### Document Reference Repair
- Converts filenames to mock_id: `"lab_results.pdf"` → `"doc-002"`
- Copies from label if missing
- Looks up from document map by name/title/summary

#### Document ID Repair
- Looks up UUID from document_reference
- Validates UUID format and correspondence
- Replaces invalid UUIDs with correct ones from document map

#### Line Number Repair
- Defaults to 1 if both missing
- Copies line_start to line_end (or vice versa) if one is missing
- Extracts from label suffix if present: `"doc-001:L101"` → line_start=101
- Swaps if line_end < line_start

#### Excerpt Repair
- Defaults to empty string if missing
- Could be extended to fetch actual content from document

### 3. Document Map

The sanitizer requires a document map with three lookup tables:

```elixir
%{
  mock_id_to_doc: %{"doc-001" => %{"id" => "uuid-...", "mock_id" => "doc-001", ...}},
  id_to_doc: %{"uuid-..." => %{"id" => "uuid-...", "mock_id" => "doc-001", ...}},
  name_to_doc: %{
    "ekg_report.pdf" => %{"id" => "uuid-...", "mock_id" => "doc-001", ...},
    "patient ekg report" => %{"id" => "uuid-...", "mock_id" => "doc-001", ...}
  }
}
```

This allows the sanitizer to resolve citations that use filenames, titles, or other document identifiers.

### 4. Repair Logging

All repairs are logged with structured information:
- Field that was repaired
- Old value
- New value
- Reason for repair

Logs are returned to the caller and can be sent to the logging system for monitoring.

## Integration

### In SectionRunner

The `SectionRunner` module has been updated to:

1. **Build document map** before sanitizing citations
2. **Sanitize citations** after receiving LLM response
3. **Log repairs** for monitoring and debugging
4. **Use cleaned citations** for persisting to database

```elixir
# In persist_success/6
{sanitized_citations, citation_repair_logs} = sanitize_citations(normalized.citations, documents)

if not Enum.empty?(citation_repair_logs) do
  CitationSanitizer.log_repairs(citation_repair_logs, %{
    section_run_id: section_run.id,
    citation_count: length(sanitized_citations)
  })
end
```

### Mock ID Generation

The mock_id generation has been updated to use **sequential numbering** (doc-001, doc-002, doc-003) based on document order, replacing the previous hash-based approach. This provides:
- **Predictable IDs** that match document order
- **Consistent numbering** across report runs
- **Easier debugging** and citation tracking

```elixir
# In run_section/5
doc_payloads =
  documents
  |> Enum.with_index(1)
  |> Enum.map(fn {doc, index} -> document_payload(doc, index) end)
```

## Usage Example

```elixir
# Build document map
document_map = %{
  mock_id_to_doc: %{"doc-001" => %{"id" => "uuid-123", ...}},
  id_to_doc: %{"uuid-123" => %{"id" => "uuid-123", "mock_id" => "doc-001"}},
  name_to_doc: %{"report.pdf" => %{"id" => "uuid-123", "mock_id" => "doc-001"}}
}

# Sanitize citations from LLM
citations = [
  %{
    "label" => "report.pdf:L50",
    "document_reference" => "report.pdf",
    "line_start" => 50
  }
]

case CitationSanitizer.sanitize_citations(citations, document_map) do
  {:ok, cleaned, logs} ->
    # All citations cleaned successfully
    # cleaned = [%{
    #   "label" => "doc-001",
    #   "document_id" => "uuid-123",
    #   "document_reference" => "doc-001",
    #   "line_start" => 50,
    #   "line_end" => 50,
    #   "excerpt" => ""
    # }]
    IO.inspect(logs)

  {:error, failed} ->
    # Some citations could not be repaired
    Enum.each(failed, fn {citation, errors} ->
      IO.puts("Failed: #{inspect(citation)}")
      IO.puts("Errors: #{inspect(errors)}")
    end)
end
```

## Testing

The module includes comprehensive tests covering:
- Valid citations (pass-through unchanged)
- Label repair (suffix stripping, pattern extraction, lookup)
- Document reference repair (filename conversion, lookup)
- Document ID repair (UUID lookup and validation)
- Line number repair (defaults, extraction, swapping)
- Excerpt repair (defaulting to empty string)
- Mixed valid and repairable citations
- Invalid citations that cannot be repaired

Run tests with:
```bash
mix test test/lumainus/ai/citation_sanitizer_test.exs
```

## Files Modified

1. **`lib/lumainus/ai/citation_sanitizer.ex`** (NEW)
   - Core sanitizer module with validation and repair logic

2. **`lib/lumainus/ai/section_runner.ex`**
   - Added `sanitize_citations/2` function
   - Added `build_sanitizer_document_map/1` function
   - Updated `persist_success/6` to sanitize citations
   - Updated `persist_failure/7` to sanitize fallback citations
   - Changed `document_payload/2` to accept sequence number
   - Removed hash-based mock_id generation

3. **`lib/lumainus/reports/cache_manager.ex`**
   - Updated `build_document_payload/2` to accept sequence number
   - Changed mock_id generation to use sequence numbers
   - Removed unused `doc_label/1` function

4. **`test/lumainus/ai/citation_sanitizer_test.exs`** (NEW)
   - Comprehensive test suite with 24 test cases

## Benefits

1. **Robustness** - Handles common LLM citation errors automatically
2. **Consistency** - All citations follow the same doc-XXX format
3. **Monitoring** - Detailed logging of repairs for quality tracking
4. **Validation** - Strict schema enforcement ensures data quality
5. **Maintainability** - Clear separation of concerns with dedicated module
6. **Testability** - Comprehensive test coverage for all repair scenarios

## Future Enhancements

1. **Excerpt fetching** - Automatically fetch excerpts from document content
2. **Fuzzy matching** - More sophisticated document lookup algorithms
3. **Citation deduplication** - Detect and merge duplicate citations
4. **Quality metrics** - Track repair rates and patterns over time
5. **Caching** - Cache document maps for performance
6. **Configuration** - Make repair strategies configurable per tenant
