# ADR-006: Migration Strategy

## Status
Proposed

## Context

Existing tenants have `report_section_templates` with minimal configuration. The refactor adds 15+ new fields and moves code to new locations. We need a safe migration path that:

1. Preserves existing prompt configurations
2. Populates new fields with sensible defaults
3. Doesn't break running report generation
4. Allows rollback if needed

## Decision

### Phase 1: Schema Migration (Database)

```elixir
# priv/repo/migrations/20251205000100_add_llm_config_fields.exs
defmodule Lumainus.Repo.Migrations.AddLlmConfigFields do
  use Ecto.Migration

  def change do
    alter table(:report_section_templates) do
      add :top_p, :float
      add :top_k, :integer
      add :candidate_count, :integer, default: 1
      add :presence_penalty, :float
      add :frequency_penalty, :float
      add :stop_sequences, {:array, :string}, default: []
      add :seed, :integer
      add :system_prompt, :text
      add :timeout_ms, :integer, default: 120_000
      add :max_retries, :integer, default: 3
      add :retry_delay_ms, :integer, default: 1000
      add :fallback_provider, :string
      add :fallback_model, :string
      add :response_mime_type, :string, default: "application/json"
    end

    alter table(:report_templates) do
      add :system_prompt, :text
      # Template defaults reuse existing :default_prompt_options map
    end

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

### Phase 2: Data Backfill + System Prompt

```elixir
# priv/repo/migrations/20251205000200_backfill_llm_defaults.exs
defmodule Lumainus.Repo.Migrations.BackfillLlmDefaults do
  use Ecto.Migration

  @default_system_prompt """
  You are Lumainus, a clinical documentation system.
  Produce structured markdown with inline citations like [doc-001].
  Return JSON that matches the provided schema exactly.
  """

  @defaults %{
    temperature: 0.2,
    top_p: 0.95,
    max_output_tokens: 2048,
    timeout_ms: 120_000,
    max_retries: 3,
    retry_delay_ms: 1000,
    candidate_count: 1,
    response_mime_type: "application/json"
  }

  def up do
    execute(fn ->
      repo = repo()

      repo.query!("""
      UPDATE report_templates
      SET system_prompt = $1
      WHERE system_prompt IS NULL
      """, [@default_system_prompt])

      Enum.each(@defaults, fn {field, value} ->
        repo.query!("""
        UPDATE report_section_templates
        SET #{field} = $1
        WHERE #{field} IS NULL
        """, [value])
      end)
    end)
  end

  def down do
    :ok
  end
end
```

### Phase 3: Code Deployment (no migration)

- Extract `Reports.Blueprints` and point seeding/helper code to it.
- Add `SchemaValidator` to `ReportSectionTemplate` changesets (and any template-level schema entry points).
- Extend `Lumainus.AI.options/1` and `Lumainus.LLM.build_request_opts/3` to honor new fields (`stop_sequences`, penalties, fallback provider/model, response_mime_type, retries).
- Establish precedence: section column → template default (`default_prompt_options`, template `system_prompt`) → application config.

### Phase 4: UI Deployment

1. Deploy new `LlmConfigLive` module
2. Add route to router (+ redirect `/prompts` to `/admin/llm-config`)
3. Update navigation to point to new page
4. Keep the old route as redirect for existing bookmarks

### Deployment Order

```
1. Run database migrations (Phase 1, Phase 2)
   - Adds columns and backfills defaults/system prompts

2. Deploy code changes
   - Blueprints module extraction
   - Schema validator + changeset wiring
   - LLM client updates to read new fields and fallback

3. Deploy UI changes
   - New LlmConfigLive page
   - Route updates

4. Verify and monitor
   - Check report generation still works
   - Verify new fields are being used
```

### Rollback Plan

**If Phase 1 fails:**
```bash
mix ecto.rollback --step 1
```

**If Phase 2 backfill fails:**
```bash
mix ecto.rollback --step 1
```

**If code breaks after deploy:**
- New fields are nullable, old code ignores them
- Revert to previous code version
- Fields remain in DB but unused

**If UI has issues:**
- UI is isolated from core report generation
- Can disable route and revert to old `/prompts` page

### Testing Checklist

```
[ ] Run migrations on staging
[ ] Generate a report with existing template
[ ] Edit a section via new UI
[ ] Verify new fields are saved correctly
[ ] Change model/provider, run section
[ ] Invalid schema shows validation error
[ ] Save blocked when schema invalid
[ ] Fallback model used when primary fails
[ ] System prompt appears in LLM request
[ ] Temperature/top_p/stop_sequences affect output
[ ] Response MIME type respected when schema omitted
```

### Feature Flags (Optional)

If gradual rollout desired:

```elixir
# config/runtime.exs
config :lumainus, :features,
  llm_config_studio: System.get_env("FEATURE_LLM_CONFIG_STUDIO", "false") == "true"

# In router
if Application.get_env(:lumainus, :features)[:llm_config_studio] do
  live "/admin/llm-config", LlmConfigLive, :index
end
```

## Consequences

### Positive
- Zero-downtime migration
- Backward compatible at each step
- Easy rollback at any phase
- Existing tenants unaffected until they use new UI

### Negative
- Multiple migrations to coordinate
- Need to update LLM client to read new fields
- Testing burden increases

### Timeline Considerations
- Phase 1-3 can ship together (DB + code)
- Phase 4 (UI) can be delayed or feature-flagged
- Feature flag allows staged rollout
