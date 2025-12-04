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

Missing parameters that Gemini API supports:
- Sampling: top_p, top_k, candidate_count
- Penalties: presence_penalty, frequency_penalty
- Control: stop_sequences, seed
- Context: system_prompt (separate from prompt_template)
- Reliability: timeout, retries, fallback model
- Output: response_format validation

## Decision

### Migration: Add LLM Parameters

```elixir
# priv/repo/migrations/20251203_add_llm_config_fields.exs
defmodule Lumainus.Repo.Migrations.AddLlmConfigFields do
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

      # Response format
      add :response_format, :string, default: "json"
    end

    alter table(:report_templates) do
      add :system_prompt, :text
      add :default_llm_config, :map, default: %{}
    end

    # Constraints for valid ranges
    create constraint(:report_section_templates, :temperature_range,
      check: "temperature IS NULL OR (temperature >= 0.0 AND temperature <= 2.0)")

    create constraint(:report_section_templates, :top_p_range,
      check: "top_p IS NULL OR (top_p >= 0.0 AND top_p <= 1.0)")
  end
end
```

### Field Groups for UI

| Group | Fields | Purpose |
|-------|--------|---------|
| **Identity** | identifier, title, position, auto_run | Section metadata |
| **Prompts** | prompt_template, system_prompt | LLM instructions |
| **Model** | provider, model, fallback_provider, fallback_model | Model selection |
| **Generation** | temperature, top_p, top_k, candidate_count | Sampling control |
| **Constraints** | max_output_tokens, stop_sequences, presence_penalty, frequency_penalty | Output limits |
| **Output** | output_schema, response_format | Structured output |
| **Reliability** | timeout_ms, max_retries, retry_delay_ms, seed | Error handling |

## Consequences

- All Gemini parameters exposed and configurable
- Type-safe with database constraints
- 15 new columns, all nullable or with defaults
- Backward compatible with existing templates
