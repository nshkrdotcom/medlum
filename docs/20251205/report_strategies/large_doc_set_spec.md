# Large / Scan-Heavy Document Set Reporting Flow (Lumainus)

Optimized for long PDFs, mixed scans/images, and multi-section reports where selective retrieval and multimodal handling are required.

## Goals
- Handle hundreds of pages and scans with reliable grounding.
- Keep prompts small via retrieval; maintain strict provenance.
- Support multi-turn/section reuse with optional caching.

## Pipeline
1) **Ingest**
   - Upload → store raw blob.
   - Docling parse to text + layout metadata + page/line anchors.
   - Vision/OCR pass on images/scanned pages; merge text with anchors.
2) **Chunking**
   - Chunk size ~300–500 tokens; include `doc_id`, `page`, `line_start/line_end`, `kind` (text/ocr/table).
   - Build hierarchical summaries: chunk → section → doc executive summary.
3) **Enrichment**
   - PII/PHI tagging (for policy), domain tagging (cardiology, labs, imaging).
   - Dedup/near-dup filter to reduce noise.
   - Embeddings: domain-appropriate model (clinical if available), store embeddings with metadata.
4) **Indexing**
   - Vector store per dataset/report (pgvector/Weaviate/Pinecone).
   - Metadata filters: doc kind, date, modality, page ranges.
   - Store summaries separately for recall.
5) **Retrieval (per section)**
   - Build section-specific query from template intent.
   - Hybrid retrieval (BM25+vector) if available; else vector with metadata filters.
   - Fetch top-k chunks + relevant summaries; keep anchors (`doc_id`, `page`, `line`).
   - Optional re-rank (lightweight) using section intent.
6) **Context Assembly**
   - Compose: short section prompt + top chunks + (optional) summaries.
   - Enforce compactness: trim to budget; prefer high-signal chunks; keep anchors in-line (“[doc-003 p12 l45-62]”).
   - If section will make multiple calls, build a **section cache** from retrieved chunks only (not the whole doc).
7) **Generation**
   - Model: reliable general or domain model; low temperature.
   - Prompts require citations for every assertion; schema includes `doc_id/page/line`.
8) **Validation**
   - JSON/schema validation.
   - Citation validator: every field must cite retrieved anchors; drop hallucinated cites.
   - Optional self-check: ask model to verify each claim cites provided sources.
9) **Persistence**
   - Save outputs, citations, usage, retrieval set (chunk IDs).
   - Record which cache (if any) was used.

## Prompts & Schemas
- Section templates: intent + constraints (“use only provided chunks; cite doc/page/line”).
- Citation schema: `{doc_id, page, line_start, line_end, uri?}`; reject if missing anchors.

## Caching Strategy
- No giant cache of full docs. Only create a per-section cache from the retrieved chunk set when:
  - Multiple turns expected in that section, or
  - The section budget is tight and reuse saves cost.
- Otherwise, single-call retrieval + generation.

## Metrics
- Recall@k on eval questions.
- Citation validity rate (anchors present and in retrieved set).
- Token cost per section; cache hit rate (if enabled).
- Latency per section.

## Fail-safes
- If retrieval returns too few chunks, broaden filters or fall back to doc summaries.
- If prompt budget exceeded, drop lower-tier chunks first, keep highest-score + summaries.
- If validation fails, retry once with stricter guidance or smaller context.
