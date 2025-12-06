# Citation Sanitizer Implementation - Summary of Changes

## Overview

Implemented a robust LLM output cleaner/validator module to handle inconsistent citations in the Lumainus reports system.

## New Files Created

### 1. `/lib/lumainus/ai/citation_sanitizer.ex`
Complete citation validation and repair module with:
- `sanitize_citations/2` - Main entry point for batch citation sanitization
- `sanitize_single_citation/2` - Sanitizes individual citation
- `validate_citation/1` - Validates citation structure and field formats
- `repair_citation/2` - Attempts to repair common LLM mistakes
- `log_repairs/2` - Logs repair information for monitoring

**Key Features:**
- Multi-stage repair pipeline (label → reference → document_id → lines → excerpt)
- Document lookup by mock_id, UUID, filename, title, or summary
- Automatic extraction of line numbers from label suffixes (e.g., "doc-001:L101")
- UUID validation and correction
- Comprehensive error reporting

### 2. `/test/lumainus/ai/citation_sanitizer_test.exs`
Comprehensive test suite with 24 test cases covering:
- Valid citation pass-through
- Label repair scenarios
- Document reference lookup and conversion
- Document ID inference
- Line number defaults and extraction
- Invalid citation handling

### 3. `/docs/CITATION_SANITIZER.md`
Complete documentation including:
- Problem statement
- Solution architecture
- Integration guide
- Usage examples
- Testing instructions
- Future enhancement ideas

## Modified Files

### 1. `/lib/lumainus/ai/section_runner.ex`

**Added:**
- `alias Lumainus.AI.CitationSanitizer` - Import sanitizer module
- `sanitize_citations/2` - Helper to sanitize citations with document map
- `build_sanitizer_document_map/1` - Builds lookup tables for sanitizer
- `normalize_for_lookup/1` - Normalizes strings for case-insensitive lookup

**Modified:**
- `run_section/5` - Now generates documents with sequential mock_ids (1, 2, 3...)
- `persist_success/6` - Sanitizes citations before persisting, logs repairs
- `persist_failure/7` - Sanitizes fallback citations
- `document_payload/2` - Changed to accept sequence number instead of generating hash-based mock_id

**Key Changes:**
```elixir
# Old: Hash-based mock_id generation
doc_payloads = Enum.map(documents, &document_payload/1)

# New: Sequential mock_id generation
doc_payloads =
  documents
  |> Enum.with_index(1)
  |> Enum.map(fn {doc, index} -> document_payload(doc, index) end)
```

```elixir
# New: Citation sanitization in persist_success
{sanitized_citations, citation_repair_logs} = sanitize_citations(normalized.citations, documents)

if not Enum.empty?(citation_repair_logs) do
  CitationSanitizer.log_repairs(citation_repair_logs, %{
    section_run_id: section_run.id,
    citation_count: length(sanitized_citations)
  })
end
```

### 2. `/lib/lumainus/reports/cache_manager.ex`

**Modified:**
- `build_documents_text/1` - Uses sequential numbering with `Enum.with_index(1)`
- `build_document_payload/2` - Changed to accept sequence number
- Added `format_mock_id/1` - Formats sequence number to doc-XXX format

**Removed:**
- `doc_label/1` - No longer needed with sequential numbering

**Key Changes:**
```elixir
# Old: Used metadata-based or hash-based mock_id
"mock_id" => metadata["mock_id"] || doc_label(doc)

# New: Uses sequential numbering
doc_payloads =
  documents
  |> Enum.with_index(1)
  |> Enum.map(fn {doc, index} -> build_document_payload(doc, index) end)

mock_id = format_mock_id(sequence_number)
```

## Technical Details

### Mock ID Generation Change

**Before:**
- Used hash of document UUID: `:erlang.phash2(doc.id, 999) + 1`
- Inconsistent between runs
- Harder to debug

**After:**
- Uses document position in list: `doc-001`, `doc-002`, `doc-003`, etc.
- Consistent and predictable
- Matches document order (most recent first, per `desc: d.inserted_at`)

### Citation Repair Pipeline

1. **Label Repair** - Strip suffixes, extract patterns, lookup filenames
2. **Document Reference Repair** - Convert filenames to mock_id, sync with label
3. **Document ID Repair** - Lookup UUID from reference, validate format
4. **Line Number Repair** - Default to 1, extract from suffix, swap if needed
5. **Excerpt Repair** - Default to empty string

### Validation Rules

All citations must have:
- `label`: Format `doc-XXX` (e.g., "doc-001")
- `document_id`: Valid UUID v4 format
- `document_reference`: Format `doc-XXX`, must match label
- `line_start`: Positive integer
- `line_end`: Positive integer >= line_start
- `excerpt`: String (can be empty)

## Testing

All tests pass:
```bash
$ mix test test/lumainus/ai/citation_sanitizer_test.exs
24 tests, 0 failures
```

Project compiles without warnings:
```bash
$ mix compile
Compiling 11 files (.ex)
Generated lumainus app
```

## Benefits

1. **Robustness** - Automatically repairs common LLM citation errors
2. **Data Quality** - Strict validation ensures all citations are well-formed
3. **Observability** - Detailed repair logging for monitoring and improvement
4. **Predictability** - Sequential mock_ids easier to understand and debug
5. **Maintainability** - Clean separation of concerns with dedicated module
6. **Testability** - Comprehensive test coverage

## Migration Notes

- Existing citations in the database are not affected
- New citations will use sequential numbering (doc-001, doc-002, etc.)
- The sanitizer is backwards-compatible with hash-based mock_ids
- No database schema changes required

## Usage

The sanitizer is automatically invoked by `SectionRunner` for all citation processing. No code changes needed in calling code.

For manual use:
```elixir
document_map = build_sanitizer_document_map(documents)
{:ok, cleaned, logs} = CitationSanitizer.sanitize_citations(citations, document_map)
```

## Future Improvements

1. Extract actual excerpts from document content
2. Add fuzzy matching for document lookup
3. Track and report citation quality metrics
4. Add citation deduplication
5. Make repair strategies configurable
