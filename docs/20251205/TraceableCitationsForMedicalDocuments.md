# Traceable Citations for Medical Documents — Ideal Workflow

Based on the existing Medlum architecture and the Medlum use case (physician burnout, EMR automation), here's an ideal workflow that makes every clinical claim defensible and auditable.

---

## Core Philosophy

**The goal isn't just "cite your sources"—it's creating an unbroken chain from any generated claim back to the exact location in the source material, with enough metadata that a physician (or auditor, or regulator) can verify it in seconds.**

---

## 1. Ingestion: Anchor Everything

### Current State
- Docling parses PDFs → Markdown with page metadata
- Documents stored with UUIDs, sequential mock_ids (doc-001, doc-002)

### Ideal Enhancement

```
┌─────────────────────────────────────────────────────────────────┐
│                    Document Ingestion                            │
│                                                                   │
│  PDF/DOCX/HL7                                                    │
│      │                                                           │
│      ▼                                                           │
│  ┌─────────────┐    ┌──────────────┐    ┌──────────────────┐   │
│  │  Docling    │───▶│  Anchor      │───▶│  Store with      │   │
│  │  Parse      │    │  Generator   │    │  Line-Level IDs  │   │
│  └─────────────┘    └──────────────┘    └──────────────────┘   │
│                            │                                     │
│                            ▼                                     │
│                     Every line gets:                             │
│                     • doc_id (UUID)                              │
│                     • page_num                                   │
│                     • line_num                                   │
│                     • char_offset_start/end                      │
│                     • content_hash (for drift detection)         │
│                     • semantic_type (heading/para/list/table)    │
└─────────────────────────────────────────────────────────────────┘
```

**Key additions:**
- **Character offsets** — Not just line numbers; exact byte positions for highlight rendering
- **Content hashes** — Detect if source document changes after citation was made
- **Semantic typing** — Know if you're citing a lab value, a medication, or narrative text

---

## 2. Citation Schema: The Minimum Viable Proof

```elixir
%Citation{
  # Identity
  id: uuid,
  claim_text: "Patient has ejection fraction of 35%",
  
  # Source anchor (the "traceable" part)
  document_id: uuid,
  document_reference: "doc-001",  # Human-readable
  page: 3,
  line_start: 47,
  line_end: 49,
  char_start: 1203,
  char_end: 1289,
  
  # Verbatim excerpt (for verification without fetch)
  excerpt: "LVEF 35% by Simpson's biplane method",
  excerpt_hash: "sha256:abc123...",
  
  # Metadata for audit
  extraction_method: :llm | :rule | :ocr | :human,
  confidence: 0.94,
  verified_by: nil | user_id,
  verified_at: nil | datetime,
  
  # Linkage
  section_run_id: uuid,  # Which generation produced this
  llm_invocation_id: uuid,  # Exact API call
  prompt_version: "v2.3.1"
}
```

### Why This Schema

| Field | Purpose |
|-------|---------|
| `excerpt + excerpt_hash` | Physician can verify without opening document; hash detects tampering |
| `char_start/end` | Enables highlight rendering in document viewer |
| `extraction_method` | Distinguishes LLM inference from rule-based extraction |
| `confidence` | Enables "low confidence" warnings in UI |
| `llm_invocation_id` | Full audit trail to exact prompt/response |

---

## 3. Generation: Enforce Citation at Prompt Level

### Current Approach
- Prompts ask LLM to cite; CitationSanitizer repairs after the fact

### Ideal Approach: Constrained Generation

```
┌────────────────────────────────────────────────────────────────┐
│                  Section Generation Flow                        │
│                                                                  │
│  ┌──────────────┐                                              │
│  │  Template    │  "For each finding, you MUST cite using:     │
│  │  Prompt      │   [doc-XXX p## L##-##]                       │
│  │              │   If you cannot cite, say 'unable to cite'"  │
│  └──────────────┘                                              │
│         │                                                       │
│         ▼                                                       │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐     │
│  │  Context     │───▶│  LLM Call    │───▶│  Parse +     │     │
│  │  (anchored   │    │  (structured │    │  Validate    │     │
│  │   chunks)    │    │   output)    │    │  Citations   │     │
│  └──────────────┘    └──────────────┘    └──────────────┘     │
│         │                                        │              │
│         │                                        ▼              │
│         │                               ┌──────────────┐       │
│         │                               │  Reject if   │       │
│         │                               │  uncited     │       │
│         │                               │  claims      │       │
│         │                               └──────────────┘       │
│         │                                        │              │
│         ▼                                        ▼              │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │                 Citation Validator                       │  │
│  │  • Does doc-001 exist in context?                       │  │
│  │  • Is page 3 within document page count?                │  │
│  │  • Does excerpt fuzzy-match content at lines 47-49?     │  │
│  │  • Is confidence above threshold for claim type?        │  │
│  └─────────────────────────────────────────────────────────┘  │
│                              │                                  │
│                              ▼                                  │
│                    ┌──────────────┐                            │
│                    │  Grounded    │                            │
│                    │  Output      │                            │
│                    └──────────────┘                            │
└────────────────────────────────────────────────────────────────┘
```

**Key principle: Claims without valid citations don't make it to the output.**

---

## 4. Validation: The "Grounding Check"

```elixir
defmodule Medlum.AI.CitationValidator do
  @doc """
  Validates that a citation actually grounds the claim it's attached to.
  """
  
  def validate(citation, document_content, claim_text) do
    with :ok <- validate_anchor_exists(citation, document_content),
         :ok <- validate_excerpt_matches(citation, document_content),
         :ok <- validate_claim_supported(citation.excerpt, claim_text) do
      {:ok, citation}
    else
      {:error, :anchor_not_found} -> {:error, "Citation points to non-existent location"}
      {:error, :excerpt_mismatch} -> {:error, "Excerpt doesn't match document content"}
      {:error, :claim_not_supported} -> {:error, "Cited text doesn't support the claim"}
    end
  end
  
  defp validate_claim_supported(excerpt, claim_text) do
    # Could use embedding similarity or rule-based check
    # Example: if claim says "EF 35%" but excerpt says "EF 55%", fail
  end
end
```

### Validation Tiers

| Tier | Check | Cost | When to Use |
|------|-------|------|-------------|
| **Basic** | Anchor exists, format valid | Cheap | Always |
| **Content** | Excerpt fuzzy-matches source | Medium | Default |
| **Semantic** | LLM verifies claim ↔ excerpt entailment | Expensive | High-stakes sections |

---

## 5. Storage: Audit-Ready Persistence

```
┌─────────────────────────────────────────────────────────────────┐
│                      Database Schema                             │
│                                                                   │
│  ┌─────────────────┐         ┌─────────────────┐                │
│  │  section_runs   │────────▶│  citations      │                │
│  │                 │   1:N   │                 │                │
│  │  • id           │         │  • id           │                │
│  │  • section_type │         │  • claim_text   │                │
│  │  • content      │         │  • document_id  │                │
│  │  • status       │         │  • page/line    │                │
│  └─────────────────┘         │  • excerpt      │                │
│         │                    │  • confidence   │                │
│         │                    │  • verified_*   │                │
│         │                    └─────────────────┘                │
│         │                            │                           │
│         │                            │                           │
│         ▼                            ▼                           │
│  ┌─────────────────┐         ┌─────────────────┐                │
│  │  llm_invocations│         │  document_      │                │
│  │                 │         │  uploads        │                │
│  │  • prompt_text  │         │                 │                │
│  │  • response_*   │         │  • raw_content  │                │
│  │  • model/token  │         │  • parsed_md    │                │
│  │  • duration     │         │  • line_index   │◀── JSON map    │
│  └─────────────────┘         │  • page_map     │    of anchors  │
│                              └─────────────────┘                │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

**`line_index`** — JSONB column mapping line numbers to character offsets and content hashes, enabling O(1) anchor lookups.

---

## 6. UI: One-Click Verification

### For Physicians

```
┌─────────────────────────────────────────────────────────────────┐
│                     Report Section                               │
│                                                                   │
│  "Patient presents with reduced ejection fraction (35%)[¹]       │
│   consistent with systolic heart failure. Recent labs show       │
│   elevated BNP (1,240 pg/mL)[²] and mild renal impairment       │
│   (GFR 48)[³]."                                                  │
│                                                                   │
│  ───────────────────────────────────────────────────────────    │
│                                                                   │
│  [¹] Cardiology Consult 11/28 p3 L47-49                         │
│      "LVEF 35% by Simpson's biplane method"                      │
│      [View in document] [Verify] [Flag issue]                    │
│                                                                   │
│  [²] Lab Results 11/30 p1 L12                                   │
│      "BNP: 1240 pg/mL (ref <100)"                               │
│      [View in document] [Verify] [Flag issue]                    │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

**Interaction:**
- **Hover** → Tooltip shows excerpt
- **Click citation number** → Document viewer opens at exact location, text highlighted
- **"Verify" button** → Marks citation as human-verified, logs to audit trail
- **"Flag issue"** → Creates review task, triggers re-generation of that claim

---

## 7. Audit Trail: The 6-Year Record

For HIPAA/regulatory compliance, every citation carries full provenance:

```elixir
%AuditRecord{
  citation_id: uuid,
  
  # What was generated
  claim_text: "EF 35%",
  generated_at: ~U[2025-12-05 10:30:00Z],
  
  # How it was generated
  model: "gemini-2.0-flash",
  prompt_version: "v2.3.1",
  llm_invocation_id: uuid,
  
  # What it cited
  document_id: uuid,
  document_version_hash: "sha256:...",  # Detect if doc changed
  anchor: %{page: 3, line_start: 47, line_end: 49},
  excerpt_at_generation: "LVEF 35% by Simpson's biplane method",
  
  # Verification chain
  validations: [
    %{type: :anchor_exists, passed: true, at: ~U[...]},
    %{type: :excerpt_match, passed: true, similarity: 0.98, at: ~U[...]},
    %{type: :human_verified, user_id: uuid, at: ~U[...]}
  ],
  
  # Changes
  modifications: []  # If claim ever edited, record here
}
```

**Retention:** 6 years per HIPAA, immutable after creation.

---

## 8. Failure Modes & Recovery

| Failure | Detection | Response |
|---------|-----------|----------|
| **Citation points to deleted document** | Hash mismatch on fetch | Surface warning, link to archived version |
| **Excerpt doesn't match (doc updated)** | Fuzzy match < threshold | Flag for re-review, show both versions |
| **LLM hallucinates citation** | Anchor doesn't exist | Block from output, log to quality metrics |
| **Low confidence on critical claim** | Confidence < threshold | Route to human review queue |
| **Conflicting citations** | Same claim, different sources | Surface conflict, require disambiguation |

---

## 9. Implementation Phases

### Phase 1: Anchor Enhancement (Now)
- Add `char_start/end` to citation schema
- Store `line_index` JSONB on document_uploads
- Update CitationSanitizer to validate anchors exist

### Phase 2: Validation Pipeline (Next)
- Add excerpt fuzzy-matching
- Add "grounding check" before persistence
- Surface validation failures in UI

### Phase 3: Verification Workflow (Soon)
- Add `verified_by/at` fields
- Build physician verification UI
- Create review queue for low-confidence citations

### Phase 4: Audit & Compliance (Later)
- Implement immutable audit log
- Add document version tracking
- Build compliance reporting dashboard

---

## 10. Metrics to Track

| Metric | Target | Why It Matters |
|--------|--------|----------------|
| **Citation validity rate** | >98% | How often anchors actually exist |
| **Excerpt match rate** | >95% | How often excerpt matches source |
| **Claim support rate** | >90% | How often cited text actually supports claim |
| **Verification rate** | >80% | How often physicians verify vs skip |
| **Flag rate** | <5% | How often physicians flag issues |
| **Time to verify** | <10s | Friction in verification workflow |

---

## Summary

The ideal workflow treats citations not as afterthoughts but as **first-class entities** with their own lifecycle:

1. **Created** with precise anchors during ingestion
2. **Required** by constrained generation prompts
3. **Validated** before reaching the output
4. **Surfaced** with one-click verification in UI
5. **Audited** with immutable 6-year retention

This gives physicians confidence that "every claim has attributable evidence" isn't marketing—it's architecture.
