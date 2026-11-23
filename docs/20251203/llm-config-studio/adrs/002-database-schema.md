# ADR-002: Database Schema Extensions

## Status
Proposed

## Context

Current `report_section_templates` table has minimal LLM configuration:
- `provider` (string, default: "google")
- `model` (string, default: "gemini-flash-lite-latest")
- `temperature` (float, nullable)
- `max_output_tokens` (integer, nullable)
- `metadata` (map, catch-all)
- `auto_run` (boolean)

Missing parameters that Gemini API supports:
- Sampling: `top_p`, `top_k`, `candidate_count`
- Penalties: `presence_penalty`, `frequency_penalty`
- Control: `stop_sequences`, `seed`
- Context: template-level `system_prompt` with optional per-section override
- Reliability: `timeout_ms`, `max_retries`, `retry_delay_ms`, fallback provider/model
- Output: `response_mime_type` override when schema is omitted
- Defaults: template-level defaults currently only available via `default_prompt_options` map

## Decision

### Migration: Add LLM Parameters

```elixir
# priv/repo/migrations/20251205000100_add_llm_config_fields.exs
defmodule Medlum.Repo.Migrations.AddLlmConfigFields do
  use Ecto.Migration

  def change do
    alter table(:report_section_templates) do
      # Sampling parameters
      add :top_p, :float
      add :top_k, :integer
      add :candidate_count, :integer, default: 1

      # Penalty parameters
      add :presence_penalty, :float
      add :frequency_penalty, :float

      # Control parameters
      add :stop_sequences, {:array, :string}, default: []
      add :seed, :integer

      # Context
      add :system_prompt, :text

      # Reliability
      add :timeout_ms, :integer, default: 120_000
      add :max_retries, :integer, default: 3
      add :retry_delay_ms, :integer, default: 1000

      # Fallback
      add :fallback_provider, :string
      add :fallback_model, :string

      # Response format / mime
      add :response_mime_type, :string, default: "application/json"
    end

    alter table(:report_templates) do
      add :system_prompt, :text
      # Reuse existing :default_prompt_options for template-level defaults
    end

    # Constraints for valid ranges
    create constraint(:report_section_templates, :temperature_range,
      check: "temperature IS NULL OR (temperature >= 0.0 AND temperature <= 2.0)")

    create constraint(:report_section_templates, :top_p_range,
      check: "top_p IS NULL OR (top_p >= 0.0 AND top_p <= 1.0)")

    create constraint(:report_section_templates, :penalty_range,
      check:
        "(presence_penalty IS NULL OR (presence_penalty >= -2.0 AND presence_penalty <= 2.0)) AND " <>
        "(frequency_penalty IS NULL OR (frequency_penalty >= -2.0 AND frequency_penalty <= 2.0))")

    create constraint(:report_section_templates, :candidate_count_positive,
      check: "candidate_count IS NULL OR candidate_count >= 1")

    create constraint(:report_section_templates, :top_k_non_negative,
      check: "top_k IS NULL OR top_k >= 0")

    create constraint(:report_section_templates, :timeout_positive,
      check: "timeout_ms IS NULL OR timeout_ms > 0")

    create constraint(:report_section_templates, :retry_non_negative,
      check: "max_retries IS NULL OR max_retries >= 0")
  end
end
```

### Defaults and Precedence
- Template-level `system_prompt` is the default; a section-level `system_prompt` overrides when present.
- Template-level default options live in the existing `report_templates.default_prompt_options` map (e.g., default `temperature`, `top_p`).
- Section-level columns override both the template defaults and application config.

### Field Groups for UI

| Group | Fields | Purpose |
|-------|--------|---------|
| **Identity** | identifier, title, position, auto_run | Section metadata |
| **Prompts** | prompt_template, system_prompt | LLM instructions |
| **Model** | provider, model, fallback_provider, fallback_model | Model selection |
| **Generation** | temperature, top_p, top_k, candidate_count | Sampling control |
| **Constraints** | max_output_tokens, stop_sequences, presence_penalty, frequency_penalty | Output limits |
| **Output** | output_schema, response_mime_type | Structured output / mime override |
| **Reliability** | timeout_ms, max_retries, retry_delay_ms, seed | Error handling |

## Consequences

- All Gemini parameters exposed and configurable
- Type-safe with database constraints
- 14 new per-section columns + template `system_prompt`, all nullable or with defaults
- Backward compatible with existing templates (old code ignores new columns)
