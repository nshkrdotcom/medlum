# Small Document Set Reporting Flow (Lumainus)

Optimized for short PDFs or a few pages where full-text fits comfortably in prompts without heavy retrieval or caching.

## Goals
- Fast, cheap runs with minimal infra.
- Deterministic, citation-friendly outputs.
- Reuse Docling parsing but avoid large caches unless needed.

## Pipeline
1) **Ingest**
   - Upload → store PDF blob (existing pipeline).
   - Docling parse to Markdown + metadata (doc kind, source, page anchors).
2) **Light Enrichment**
   - Generate per-doc “fact sheet” summary (≈300–500 tokens) with key findings and page references.
   - Keep page/line anchors from Docling for citations.
3) **Context Assembly (per section)**
   - Inputs: patient profile, doc fact sheets, selected salient snippets (optionally top N by heuristic: headings + first/last para per doc).
   - No embeddings/retrieval needed; keep prompt under budget (e.g., <10k tokens).
4) **Prompting**
   - Section template + system prompt.
   - Include doc labels + page refs in the context (“[doc-001 p3] …”).
   - Require citations in the schema (URI/page/line).
5) **Generation**
   - Single LLM call (no cache). Model: fast general model (Gemini Flash/Claude Haiku/Opus-lite equivalent), temperature low.
6) **Validation**
   - JSON/schema validation for structured output.
   - Citation check: every claim requires a citation; reject if missing.
7) **Persistence**
   - Save outputs, citations, usage; log provenance (doc/page anchors).

## Prompts & Schemas
- Templates: concise, role-bound (“You are a clinical summarizer; use only provided context”).
- Schema: enforce citations per answer field; include `source_id`, `page`, `line_range`.

## When to Cache
- Only if estimated tokens > threshold (e.g., >15k) or multiple sections reuse identical context. Otherwise skip cache to keep latency low.

## Metrics
- Turnaround time per section.
- Citation coverage (% fields with cites).
- Token cost per run.
- Validation failure rate.

## Fail-safes
- If context > budget, fall back to: drop low-importance snippets, keep fact sheets only.
- If schema validation fails, auto-retry once with higher guidance (re-prompt with “fix JSON”).
