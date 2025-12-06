# Citation Sanitizer - Data Flow

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         SectionRunner                                │
│                                                                       │
│  ┌─────────────┐         ┌──────────────┐         ┌──────────────┐ │
│  │  Documents  │────────>│  LLM Client  │────────>│  Normalize   │ │
│  │  (seq 1,2,3)│         │  (Gemini)    │         │  Response    │ │
│  └─────────────┘         └──────────────┘         └──────────────┘ │
│         │                                                   │         │
│         │                                                   v         │
│         │                                          ┌──────────────┐ │
│         │                                          │  Citations   │ │
│         │                                          │  (raw LLM)   │ │
│         │                                          └──────────────┘ │
│         │                                                   │         │
│         v                                                   v         │
│  ┌─────────────────┐                             ┌──────────────┐ │
│  │ Build Document  │                             │  Sanitize    │ │
│  │     Map         │────────────────────────────>│  Citations   │ │
│  └─────────────────┘                             └──────────────┘ │
│         │                                                   │         │
│         │                                                   v         │
│         │                                          ┌──────────────┐ │
│         │                                          │   Cleaned    │ │
│         │                                          │  Citations   │ │
│         │                                          └──────────────┘ │
│         │                                                   │         │
│         v                                                   v         │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │                    Persist to Database                        │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
```

## Document Map Structure

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Document Map                                  │
│                                                                        │
│  ┌─────────────────────┐                                             │
│  │  mock_id_to_doc     │   {"doc-001" => %{id, mock_id, label, ...}} │
│  │                     │   {"doc-002" => %{id, mock_id, label, ...}} │
│  └─────────────────────┘                                             │
│                                                                        │
│  ┌─────────────────────┐                                             │
│  │  id_to_doc          │   {"uuid-xxx" => %{id, mock_id, ...}}       │
│  │                     │   {"uuid-yyy" => %{id, mock_id, ...}}       │
│  └─────────────────────┘                                             │
│                                                                        │
│  ┌─────────────────────┐                                             │
│  │  name_to_doc        │   {"ekg_report.pdf" => %{id, mock_id, ...}} │
│  │                     │   {"lab results" => %{id, mock_id, ...}}    │
│  └─────────────────────┘                                             │
│                                                                        │
└──────────────────────────────────────────────────────────────────────┘
```

## Citation Repair Pipeline

```
┌──────────────────────────────────────────────────────────────────────┐
│                     Raw LLM Citation                                  │
│  {                                                                    │
│    "label": "ekg_report.pdf:L50",                                    │
│    "document_reference": "ekg_report.pdf",                           │
│    "line_start": null                                                │
│  }                                                                    │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  v
┌──────────────────────────────────────────────────────────────────────┐
│                      Stage 1: Label Repair                            │
│                                                                        │
│  Input:  "ekg_report.pdf:L50"                                        │
│  Action: Split suffix, extract line number, mark for lookup          │
│  Output: label="ekg_report.pdf", __line_hint__="L50",                │
│          __needs_label_lookup__=true                                 │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  v
┌──────────────────────────────────────────────────────────────────────┐
│                 Stage 2: Document Reference Repair                    │
│                                                                        │
│  1. Lookup label in name_to_doc: "ekg_report.pdf" → doc-001         │
│  2. Update label: "ekg_report.pdf" → "doc-001"                       │
│  3. Lookup reference in name_to_doc: "ekg_report.pdf" → doc-001     │
│  4. Update reference: "ekg_report.pdf" → "doc-001"                   │
│                                                                        │
│  Result: label="doc-001", document_reference="doc-001"               │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  v
┌──────────────────────────────────────────────────────────────────────┐
│                   Stage 3: Document ID Repair                         │
│                                                                        │
│  1. Lookup document_id from mock_id "doc-001"                        │
│  2. Find: {"doc-001" => %{"id" => "uuid-123", ...}}                  │
│  3. Set document_id: "uuid-123"                                      │
│                                                                        │
│  Result: document_id="uuid-123"                                      │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  v
┌──────────────────────────────────────────────────────────────────────┐
│                   Stage 4: Line Number Repair                         │
│                                                                        │
│  1. Extract line from hint: __line_hint__="L50" → 50                 │
│  2. Set line_start: 50                                               │
│  3. Set line_end: 50 (copy from line_start)                          │
│  4. Remove temporary field: __line_hint__                            │
│                                                                        │
│  Result: line_start=50, line_end=50                                  │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  v
┌──────────────────────────────────────────────────────────────────────┐
│                     Stage 5: Excerpt Repair                           │
│                                                                        │
│  1. Check if excerpt exists: null                                    │
│  2. Default to empty string: ""                                      │
│                                                                        │
│  Result: excerpt=""                                                  │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  v
┌──────────────────────────────────────────────────────────────────────┐
│                      Validation Check                                 │
│                                                                        │
│  ✓ label: "doc-001" (matches doc-XXX pattern)                        │
│  ✓ document_id: "uuid-123" (valid UUID)                              │
│  ✓ document_reference: "doc-001" (matches doc-XXX pattern)           │
│  ✓ line_start: 50 (positive integer)                                 │
│  ✓ line_end: 50 (>= line_start)                                      │
│  ✓ excerpt: "" (string)                                              │
│                                                                        │
│  Status: VALID ✓                                                      │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  v
┌──────────────────────────────────────────────────────────────────────┐
│                     Cleaned Citation                                  │
│  {                                                                    │
│    "label": "doc-001",                                               │
│    "document_id": "uuid-123",                                        │
│    "document_reference": "doc-001",                                  │
│    "line_start": 50,                                                 │
│    "line_end": 50,                                                   │
│    "excerpt": ""                                                     │
│  }                                                                    │
└──────────────────────────────────────────────────────────────────────┘
```

## Repair Log Example

```elixir
[
  %{
    field: :label,
    old_value: "ekg_report.pdf:L50",
    new_value: "ekg_report.pdf",
    reason: "Stripped line suffix: L50"
  },
  %{
    field: :label,
    old_value: "ekg_report.pdf",
    new_value: "doc-001",
    reason: "Looked up from document map"
  },
  %{
    field: :document_reference,
    old_value: "ekg_report.pdf",
    new_value: "doc-001",
    reason: "Looked up from document"
  },
  %{
    field: :document_id,
    old_value: nil,
    new_value: "550e8400-e29b-41d4-a716-446655440000",
    reason: "Looked up from document_reference"
  },
  %{
    field: :line_numbers,
    old_value: nil,
    new_value: 50,
    reason: "Defaulted from hint or to 1"
  },
  %{
    field: :excerpt,
    old_value: nil,
    new_value: "",
    reason: "Defaulted to empty string"
  }
]
```

## Integration Points

### 1. SectionRunner.run_section/5
```elixir
# Documents with sequential mock_ids
doc_payloads =
  documents
  |> Enum.with_index(1)
  |> Enum.map(fn {doc, index} -> document_payload(doc, index) end)
```

### 2. SectionRunner.persist_success/6
```elixir
# Sanitize citations
{sanitized_citations, citation_repair_logs} =
  sanitize_citations(normalized.citations, documents)

# Log repairs
if not Enum.empty?(citation_repair_logs) do
  CitationSanitizer.log_repairs(citation_repair_logs, %{
    section_run_id: section_run.id,
    citation_count: length(sanitized_citations)
  })
end
```

### 3. SectionRunner.build_sanitizer_document_map/1
```elixir
# Build lookup tables
%{
  mock_id_to_doc: documents |> Enum.map(...) |> Map.new(),
  id_to_doc: documents |> Enum.map(...) |> Map.new(),
  name_to_doc: documents |> Enum.flat_map(...) |> Map.new()
}
```

## Error Handling

### Repairable Errors
- Missing fields → Default or infer from other fields
- Wrong format → Convert or lookup correct format
- Invalid values → Validate and correct

### Non-Repairable Errors
```elixir
{:error, [
  {
    %{"label" => "unknown", ...},
    [
      "label must be in format 'doc-XXX' (e.g., 'doc-001'), got: unknown",
      "document_id is required",
      "line_start: required"
    ]
  }
]}
```

## Performance Considerations

1. **Batch Processing** - All citations sanitized in single pass
2. **Early Return** - Valid citations skip repair pipeline
3. **Efficient Lookups** - Document map uses Map for O(1) lookups
4. **Minimal Allocation** - Repair logs only created when repairs occur
5. **No External Calls** - All processing in-memory

## Monitoring

Repair logs provide insights into:
- Most common LLM errors
- Documents with naming issues
- Citation quality trends
- Effectiveness of prompt engineering

Example log output:
```
[CitationSanitizer] Repaired 6 citation issues
Section Run ID: 550e8400-e29b-41d4-a716-446655440000
Total Citations: 12
Repairs:
  - label (2x): Stripped line suffix: L50, Looked up from document map
  - document_reference (1x): Looked up from document
  - document_id (2x): Looked up from document_reference
  - excerpt (1x): Defaulted to empty string
```
