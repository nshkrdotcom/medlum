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
# priv/repo/migrations/20251203100000_add_llm_config_fields.exs
defmodule Lumainus.Repo.Migrations.AddLlmConfigFields do
  use Ecto.Migration

  def change do
    # All new fields are nullable or have defaults
    # This is backward compatible - existing code continues to work

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
      add :response_format, :string, default: "json"
    end

    alter table(:report_templates) do
      add :system_prompt, :text
      add :default_llm_config, :map, default: %{}
    end
  end
end
```

### Phase 2: Code Migration (Blueprints Module)

```elixir
# priv/repo/migrations/20251203100001_create_blueprints_module.exs
# This is a code-only migration marker - no DB changes
defmodule Lumainus.Repo.Migrations.CreateBlueprintsModuleMarker do
  use Ecto.Migration

  def change do
    # No-op migration to mark the code refactor in migration history
    # Actual work is in lib/lumainus/reports/blueprints.ex
    execute "SELECT 1", "SELECT 1"
  end
end
```

### Phase 3: Data Backfill (Optional)

If we want to populate defaults for existing sections:

```elixir
# priv/repo/migrations/20251203100002_backfill_llm_defaults.exs
defmodule Lumainus.Repo.Migrations.BackfillLlmDefaults do
  use Ecto.Migration
  import Ecto.Query

  @defaults %{
    temperature: 0.2,
    top_p: 0.95,
    max_output_tokens: 2048,
    timeout_ms: 120_000,
    max_retries: 3,
    retry_delay_ms: 1000,
    candidate_count: 1,
    response_format: "json"
  }

  def up do
    # Only update sections that have NULL for these fields
    from(s in "report_section_templates",
      where: is_nil(s.temperature),
      update: [set: [temperature: ^@defaults.temperature]]
    )
    |> repo().update_all([])

    # Similar for other fields...
  end

  def down do
    # No rollback needed - we're just filling NULLs
    :ok
  end
end
```

### Phase 4: System Prompt Extraction

Move the hard-coded system prompt to database:

```elixir
# priv/repo/migrations/20251203100003_populate_system_prompts.exs
defmodule Lumainus.Repo.Migrations.PopulateSystemPrompts do
  use Ecto.Migration

  @default_system_prompt """
  You are Lumainus, a clinical documentation system.
  Produce structured markdown with inline citations like [doc-001].
  Return JSON that matches the provided schema exactly.
  """

  def up do
    # Set template-level system prompt
    execute """
    UPDATE report_templates
    SET system_prompt = '#{@default_system_prompt}'
    WHERE system_prompt IS NULL
    """
  end

  def down do
    execute """
    UPDATE report_templates
    SET system_prompt = NULL
    """
  end
end
```

### Phase 5: UI Deployment

1. Deploy new `LlmConfigLive` module
2. Add route to router
3. Update navigation to point to new page
4. Keep old `/prompts` route as redirect for bookmarks

```elixir
# router.ex
live "/prompts", LlmConfigLive, :index  # Redirect old URL
live "/admin/llm-config", LlmConfigLive, :index  # New canonical URL
```

### Deployment Order

```
1. Run database migrations (Phase 1, 3, 4)
   - Adds columns, no code dependency

2. Deploy code changes
   - Blueprints module extraction
   - Schema updates
   - LLM client updates to read new fields

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
[ ] Temperature/top_p affect output
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
- Phase 1-4: Can run together in single deploy
- Phase 5: Can be delayed until UI is ready
- Feature flag allows staged rollout
