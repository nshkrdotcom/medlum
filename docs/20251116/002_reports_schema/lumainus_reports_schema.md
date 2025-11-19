# Lumainus Reports Data Architecture (v1)

**Date:** 2025-11-16  
**Owner:** Lumainus AI Agents  
**Scope:** `/reports` ingestion → LLM analysis → structured report delivery  
**Goal:** Land the first single-tenant deployment while keeping schemas tenancy-aware so we can onboard additional domains without rewrites.

---

## 1. Requirements Recap
- `/reports` must pull from a **traceable ingestion pipeline**: PDF upload → parsing → LLM summarization (markdown) → report UI.
- Every artifact (uploads, prompts, outputs, provenance) lives in Postgres with timestamps and FK chains for HIPAA audits.
- Multi-tenancy: start with one tenant, but all domain objects need a `tenant_id` (or derivable tenant) and role-aware access via `Lumainus.Accounts.Scope`.
- Patients are deduplicated + versioned (slowly changing dimension) because the LLM may update demographics over time but we keep the full history.
- `/reports` runs per patient, per template section; each run makes **one GeminiEx structured-output call** through the LLM facade.
- Logs: store prompts, responses, tool metadata, provider usage metrics, human edits.

---

## 2. Tenancy & Access Control

| Table | Purpose | Notes |
| --- | --- | --- |
| `tenants` | Primary tenant/org record | One row today (Lumainus Clinical) |
| `tenant_domains` | Domain/email routing + hostnames | Allows future `tenant.foo.com` |
| `tenant_settings` | JSONB configs (LLM limits, storage caps) | Type-2 history using `effective_at` columns |
| `users` | Existing table gains `tenant_id`, `locale`, `timezone` | `role` stays (guest, doctor, admin, system_administrator) |
| `user_memberships` | Optional future extension if users can join multiple tenants | For now `users.tenant_id` is required but schema supports pivot |

`Lumainus.Accounts.Scope` will embed both `tenant` and `user`, so downstream queries always filter by `tenant_id`.

---

## 3. Patient & Clinical Records

| Table | Columns (key fields) | Description |
| --- | --- | --- |
| `patients` | `id`, `tenant_id`, `patient_key`, `current_profile_id`, timestamps | Stable identity per patient + pointer to current profile |
| `patient_profiles` | `id`, `patient_id`, `given_name`, `family_name`, `mrn`, `dob`, `sex`, `parsed_from_upload_id`, `effective_at`, `superseded_at` | Slowly changing dimension (type 2). Each ingestion pass can create a new profile if data changes |
| `patient_notes` | `id`, `patient_id`, `author_user_id`, `body`, `visibility` | Manual adjustments & audit trail |

SCD pattern lets clinicians correct auto-detected names while preserving provenance (older reports still refer to prior profile rows).

---

## 4. Document Ingestion Workflow

### Upload Artifacts
| Table | Key fields | Notes |
| --- | --- | --- |
| `document_uploads` | `id`, `tenant_id`, `patient_id` (nullable until parsing), `uploader_id`, `filename`, `byte_size`, `content_type`, `status`, `sha256`, `storage_backend`, `stored_path`, `raw_blob` (BYTEA) | Stores PDF blob (Postgres `:binary` for now) + metadata. Flag `status` = `:pending`, `:parsed`, `:failed`. |
| `document_parses` | `id`, `upload_id`, `parser`, `parsed_text`, `structured_metadata`, `extracted_at`, `patient_profile_id` | Holds OCR/text extraction & parsed fields for ingestion. |
| `document_chunks` | `id`, `parse_id`, `position`, `content`, `token_count` | Pre-chunked text (for future embeddings). |

### Workflow Orchestration
| Table | Key fields | Notes |
| --- | --- | --- |
| `ingestion_jobs` | `id`, `tenant_id`, `upload_id`, `job_type`, `status`, `error`, `attempts`, `scheduled_at`, `started_at`, `finished_at` | Generic job log (upload ingest, reparse, vectorize). |
| `ingestion_events` | `id`, `job_id`, `event_type`, `payload`, `recorded_at` | Timeline for troubleshooting (parser selected, patient found, etc.). |

---

## 5. Reporting Templates & Sections

| Table | Key fields | Description |
| --- | --- | --- |
| `report_templates` | `id`, `tenant_id`, `name`, `slug`, `description`, `status`, `version`, `default_prompt_options` | Defines a bundle of sections (e.g., “Cardiology Initial Assessment”). |
| `report_section_templates` | `id`, `template_id`, `identifier`, `title`, `prompt_template`, `output_schema`, `order`, `auto_run`, `provider`, `model`, `temperature`, `max_output_tokens` | Each section corresponds to one button in `/reports`. `output_schema` stores NimbleOptions definitions for the structured responses expected by the LLM. |
| `report_template_documents` | `template_id`, `document_kind`, `required` | Declares which doc types feed a template (future-proof). |

Sections inject concatenated document text + structured metadata when building prompts.

---

## 6. LLM Execution & Provenance

| Table | Key fields | Notes |
| --- | --- | --- |
| `llm_invocations` | `id`, `tenant_id`, `provider`, `model`, `prompt_context`, `response_text`, `response_object`, `usage`, `status`, `error`, `temperature`, `max_output_tokens`, `req_duration_ms`, `request_id` | Canonical log for every GeminiEx call (structured outputs stored in `response_object`). |
| `report_runs` | `id`, `tenant_id`, `patient_id`, `template_id`, `triggered_by_user_id`, `run_type`, `status`, `started_at`, `finished_at`, `llm_invocation_summary_id` | Represents running ALL sections or a subset. |
| `report_section_runs` | `id`, `report_run_id`, `section_template_id`, `status`, `llm_invocation_id`, `prompt_inputs`, `output_markdown`, `output_object`, `confidence_score`, `error`, `inline_citations`, `provenance_graph` | Each section’s execution + parsed structured output. |
| `report_section_citations` | `id`, `section_run_id`, `document_id`, `source_span`, `citation_label` | Grounds inline citations to documents. |
| `report_section_feedback` | `id`, `section_run_id`, `author_user_id`, `note`, `resolution` | Tracks clinician review results. |

`prompt_inputs` is JSON storing resolved template variables (list of document IDs, chunk IDs, patient profile snapshot, etc.). `provenance_graph` stores an array of references to `document_chunks` enabling “hover to see source” UI.

---

## 7. Finished Artifacts & Audit

| Table | Key fields | Description |
| --- | --- | --- |
| `reports` | `id`, `tenant_id`, `patient_id`, `template_id`, `report_run_id`, `title`, `summary`, `body`, `status`, `published_at`, `superseded_by_id` | Materialized clinician-facing report (aggregate of section outputs). |
| `report_versions` | `id`, `report_id`, `version`, `body`, `structured_payload`, `generated_from_run_id`, `created_by_user_id` | Full history of edits, enabling rollbacks. |
| `audit_logs` | `id`, `tenant_id`, `actor_id`, `event_type`, `entity_type`, `entity_id`, `metadata` | Already partially available? (If not, this table anchors cross-cutting audits). |

Published reports always point to the exact section run + patient profile used at generation time.

---

## 8. LLM Abstraction (GeminiEx Facade)

- **Provider registry:** Store provider + model on `report_section_templates`. Default to `"google:gemini-flash-lite-latest"` but keep columns for overrides.
- **Structured outputs:** `report_section_templates.output_schema` holds NimbleOptions definitions. The runner converts those definitions into the JSON schema that `GeminiEx` expects as a `response_schema`.
- **Key management:** Configure `:gemini_ex` via runtime config (`GEMINI_API_KEY`/`GOOGLE_API_KEY`). Tenants may later carry their own API keys through `tenant_settings`.
- **Service module outline:**
  ```elixir
  defmodule Lumainus.AI.SectionRunner do
    @behaviour Lumainus.AI.Runner

    def run(section_template, documents, patient_profile, opts) do
      context = build_context(...)
      schema = section_template.output_schema
      model = section_template.model || default_model(section_template.provider)

      {:ok, response} =
        Lumainus.LLM.generate_object(
          model,
          render_prompt(context),
          schema,
          temperature: section_template.temperature,
          max_output_tokens: section_template.max_output_tokens,
          system_instruction: system_prompt()
        )

      persist(response, context, ...)
    end
  end
  ```

---

## 9. Migration Plan (Chronological)

1. **Tenancy core** – create `tenants`, `tenant_domains`, `tenant_settings`; backfill default tenant; add `tenant_id` FK to `users`.
2. **Patients** – create `patients`, `patient_profiles`, `patient_notes`.
3. **Documents & ingestion** – `document_uploads`, `document_parses`, `document_chunks`, `ingestion_jobs`, `ingestion_events`.
4. **Templates** – `report_templates`, `report_section_templates`, `report_template_documents`.
5. **LLM logging & runs** – `llm_invocations`, `report_runs`, `report_section_runs`, `report_section_citations`, `report_section_feedback`.
6. **Final artifacts** – `reports`, `report_versions`, plus optional `audit_logs`.

Each migration enforces foreign keys (`on_delete: :restrict`) to guarantee provenance. Index `tenant_id` + `patient_id` combos for all major tables to keep queries scoped.

---

## 10. Open Considerations

- **Future multi-tenant strategies:** When we allow cross-tenant admins, shift to `user_memberships` and drop the `users.tenant_id` NOT NULL constraint, but data model already supports it.
- **Vector search backend:** For now we store chunk text + token counts; future embeddings can add `document_chunk_embeddings`.
- **Large binary storage:** Postgres BYTEA works initially; migrate to S3/GCS via `storage_backend` column when needed—schema already supports remote references.
- **Scheduler integration:** `ingestion_jobs` intentionally generic so Oban/Verk/GenStage can reuse the same rows without schema churn.
- **Inline citations:** `report_section_citations.source_span` stores tuple `{chunk_id, start_offset, end_offset}` encoded as JSON so UI can highlight spans precisely.
- **Patient dedupe:** We rely on `patient_key` (hash of name+dob) + manual review to merge duplicates; merging will point both patient IDs to a single `surviving_patient_id` column later if needed.

---

This document is the contract for implementing `/reports` end-to-end: once migrations + contexts follow it, every ingestion + report action is traceable, multi-tenant ready, and LLM-auditable.
