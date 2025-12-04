# ADR-001: LLM Config Studio - Overview

## Status
Proposed

## Context

The current `/prompts` page only exposes two configurable fields:
- `prompt_template` per section
- `ingestion_prompt_template` for PDF ingestion

However, the underlying system supports many more LLM configuration options that are either:
1. Hard-coded in application code (system prompt in `section_runner.ex:17-19`)
2. Stored in the database but not exposed in the UI (provider, model, temperature)
3. Missing entirely from the schema (top_p, penalties, fallbacks)

Users need full control over LLM behavior without code changes.

## Decision

Refactor the reports/LLM system to make **everything configurable** through a new "LLM Config Studio" interface, while keeping the 11 report section definitions as the only hard-coded element (moved to a clean, obvious location).

### Scope of Changes

| ADR | Topic |
|-----|-------|
| ADR-002 | Database schema extensions |
| ADR-003 | Blueprints module extraction |
| ADR-004 | JSON Schema validation for Gemini |
| ADR-005 | UI architecture (tabbed interface) |
| ADR-006 | Migration strategy |

### What Becomes Configurable

| Category | Parameters |
|----------|------------|
| **Model Selection** | provider, model, fallback_provider, fallback_model |
| **Generation** | temperature, max_output_tokens, top_p, top_k, candidate_count |
| **Constraints** | stop_sequences, presence_penalty, frequency_penalty |
| **Structured Output** | output_schema (JSON Schema), response_format |
| **Context** | system_prompt (separate from user prompt), seed |
| **Operational** | timeout_ms, max_retries, retry_delay_ms |

### What Stays Hard-Coded

The 11 report section **identifiers and clinical focus** remain hard-coded because:
- They define the structure referenced in code and migrations
- They represent a specific clinical workflow (Cardiology Intake)
- Changing them would break existing tenant data

These move to `lib/lumainus/reports/blueprints.ex` (see ADR-003).

## Consequences

### Positive
- Full LLM control without code deploys
- Per-section model/parameter tuning
- A/B testing different configurations
- Cost optimization (cheaper models for simple sections)
- Future-proof for new Gemini parameters

### Negative
- More complex UI to build and maintain
- Risk of misconfiguration (mitigated by validation)
- Migration complexity for existing tenants

### Neutral
- Larger database footprint per section template
- More fields to document and support
