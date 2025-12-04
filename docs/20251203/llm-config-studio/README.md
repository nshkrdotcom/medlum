# LLM Config Studio - Refactor Plan

## Overview

This document set describes the refactoring of the `/prompts` page into a comprehensive "LLM Config Studio" that exposes all configurable LLM parameters through a utilitarian but cohesive UI.

## Problem Statement

Current state:
- Only `prompt_template` and `ingestion_prompt_template` are editable in UI
- Model, temperature, schema, and other parameters require DB access
- System prompt is hard-coded in `section_runner.ex`
- Section blueprints are buried in `reports.ex` (836 lines)
- No validation of JSON schemas before save

Desired state:
- **Everything** configurable through the UI
- Only the 11 section identifiers remain hard-coded (in obvious location)
- Full validation of structured output schemas
- Per-section model/parameter tuning

## Architecture Decision Records

| ADR | Title | Summary |
|-----|-------|---------|
| [001](adrs/001-overview.md) | Overview | Scope and high-level decisions |
| [002](adrs/002-database-schema.md) | Database Schema | New columns for LLM parameters |
| [003](adrs/003-blueprints-module.md) | Blueprints Module | Extract hard-coded sections to dedicated module |
| [004](adrs/004-schema-validation.md) | Schema Validation | UI-side JSON Schema validation for Gemini |
| [005](adrs/005-ui-architecture.md) | UI Architecture | New tabbed configuration interface |
| [006](adrs/006-migration-strategy.md) | Migration Strategy | Safe deployment path |

## Key Decisions

### What Becomes Configurable

| Category | Parameters |
|----------|------------|
| **Model** | provider, model, fallback_provider, fallback_model |
| **Generation** | temperature, max_output_tokens, top_p, top_k, candidate_count |
| **Constraints** | stop_sequences, presence_penalty, frequency_penalty |
| **Output** | output_schema, response_format |
| **Context** | system_prompt, seed |
| **Reliability** | timeout_ms, max_retries, retry_delay_ms |

### What Stays Hard-Coded

The 11 section **identifiers** move to `lib/lumainus/reports/blueprints.ex`:

1. chief-complaint
2. history-present-illness
3. past-history
4. medications
5. physical-exam-history
6. review-of-systems
7. lab-review
8. imaging-review
9. pathology-review
10. assessment
11. plan

These define the structure referenced in code and migrations. Their prompts, schemas, and LLM settings are all configurable.

## Implementation Summary

### New Files

```
lib/lumainus/reports/blueprints.ex          # Hard-coded section definitions
lib/lumainus/reports/schema_validator.ex    # JSON Schema validation
lib/lumainus_web/live/admin/llm_config_live.ex  # New config UI
```

### Modified Files

```
lib/lumainus/reports.ex                     # Remove blueprints, use Blueprints module
lib/lumainus/reports/report_section_template.ex  # Add new schema fields
lib/lumainus/ai/section_runner.ex           # Read new fields, use DB system_prompt
lib/lumainus/llm.ex                         # Pass new parameters to Gemini
config/config.exs                           # Update default values
```

### Migrations

```
20251203100000_add_llm_config_fields.exs    # Add columns
20251203100001_backfill_llm_defaults.exs    # Populate defaults
20251203100002_populate_system_prompts.exs  # Move system prompt to DB
```

## UI Layout

```
┌─────────────────────────────────────────────────────────────────┐
│ LLM Config Studio                                               │
├──────────────────┬──────────────────────────────────────────────┤
│  SECTIONS        │  ┌─ Section Name ────────────────────────┐   │
│  ─────────────   │  │ [Prompts] [Model] [Generation]        │   │
│  ● Chief Comp... │  │ [Output] [Advanced]                   │   │
│  ○ History...    │  │ ─────────────────────────────────────│   │
│  ○ ...           │  │ (Tab content here)                    │   │
│                  │  │                                       │   │
│  ─────────────   │  │ [Save Section]                        │   │
│  PDF Ingestion   │  └───────────────────────────────────────┘   │
│  [textarea]      │                                              │
│  [Save]          │                                              │
└──────────────────┴──────────────────────────────────────────────┘
```

## Deployment Path

1. **Database migrations** - Add columns (backward compatible)
2. **Code changes** - Blueprints extraction, schema updates
3. **UI deployment** - New LlmConfigLive page
4. **Route update** - Redirect `/prompts` to `/admin/llm-config`

All phases are independently reversible.

## Open Questions

1. Should we version section configurations for audit?
2. Do we need per-tenant model allowlists?
3. Should schema templates be provided for common patterns?
4. Is a visual schema builder needed, or is JSON sufficient?
