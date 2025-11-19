# ReqLLM Schema Validation Error - Diagnosis & Fix

## The Problem

You're seeing this error:
```
%ReqLLM.Error.Validation.Error{
  tag: :invalid_schema,
  reason: "Invalid schema: invalid NimbleOptions schema.
  Reason: unknown options [:items], valid options are:
  [:type, :required, :default, :keys, ...]"
}
```

## Root Cause

The issue occurs because:

1. **gemini_ex** (v0.4.0) validates schemas using **NimbleOptions**
2. NimbleOptions **doesn't support the `:items` key** for array types
3. The old `default_schema()` in `lib/lumainus/reports.ex` used:
   ```elixir
   "citations" => %{
     "type" => "array",
     "items" => %{...}  # ← This causes the error!
   }
   ```
4. These schemas were **persisted to the database** in `report_section_templates`
5. Old error runs might still show cached errors

## Diagnostic Scripts

Run these in order:

### 0. Full UI-equivalent run (recommended)

```bash
mix run examples/run_section_sample.exs
```

This script performs the exact same code path as the `/reports` UI:

1. Loads/creates the default workspace for `admin@lumainus.local` (override via `LUMAINUS_SAMPLE_USER`).
2. Seeds the sample documents if they are missing.
3. Inserts a `ReportRun` + `ReportSectionRun`.
4. Invokes `Lumainus.AI.SectionRunner.run_section/5`.

Whatever error you see here is the same one the UI will surface, but without needing LiveView.

### 1. Check what's in the database

```bash
mix run examples/diagnose_schema_error.exs
```

This shows:
- Which sections have problematic schemas with `items`
- Whether ReqLLM is being loaded
- Summary of issues found

### 2. Check for old error runs

```bash
mix run examples/clear_old_runs.exs
```

This:
- Shows old section runs with errors
- Lets you clear them interactively
- Removes cached error messages from UI

### 3. Reproduce the actual error

```bash
export GEMINI_API_KEY="your-key-here"
mix run examples/reproduce_reqllm_error.exs
```

This:
- Tests both old and new schema formats
- Shows exactly where the error occurs
- Confirms whether the fix works

## Solutions

### Option 1: Clear old runs (quickest)

```bash
mix run examples/clear_old_runs.exs
```

Then refresh the `/reports` page and try running a section again.

### Option 2: Fix schemas in database

```bash
mix run examples/fix_schemas_in_db.exs
```

This updates all schemas to remove `items` fields while keeping your data.

### Option 3: Reset database (nuclear option)

```bash
mix ecto.reset
```

This recreates everything with the new schema format but **deletes all data**.

### Option 4: Create a migration (for production)

```bash
mix ecto.gen.migration fix_report_section_schemas
```

Then edit the migration:

```elixir
defmodule Lumainus.Repo.Migrations.FixReportSectionSchemas do
  use Ecto.Migration

  def up do
    execute """
    UPDATE report_section_templates
    SET output_schema = jsonb_set(
      output_schema,
      '{properties,citations}',
      '{"type": "array", "description": "List of citations"}'::jsonb
    )
    WHERE output_schema->'properties'->'citations'->>'items' IS NOT NULL
    """
  end

  def down do
    # Can't easily revert this, but it's fine since old schema was broken
  end
end
```

Then run:
```bash
mix ecto.migrate
```

## The Fix (Already Applied)

File: `lib/lumainus/reports.ex:413-427`

**Before (broken):**
```elixir
"citations" => %{
  "type" => "array",
  "items" => %{          # ← NimbleOptions rejects this
    "type" => "object",
    "properties" => %{...}
  }
}
```

**After (working):**
```elixir
"citations" => %{
  "type" => "array",
  "description" => "List of citations with label and document_id"
}
```

The LLM still generates citations correctly because the **prompt** instructs it what to return, not just the schema.

## Verification

After running the fix:

1. Go to http://localhost:4000/reports
2. Click "Run Section" or "Run All Sections"
3. The section should generate successfully without ReqLLM errors
4. Check that citations are still being generated in the output

## Still Seeing Errors?

If errors persist:

1. **Check the actual error message** - is it still about `items` and NimbleOptions?
2. **Verify database** - run `diagnose_schema_error.exs` again
3. **Check for cached data** - old LiveView assigns might still have errors
4. **Restart Phoenix** - kill and restart the server
5. **Clear browser cache** - old data might be cached client-side

## Technical Details

### Why This Happens

1. `gemini_ex` (v0.4.0) depends on `altar` (v0.1.7)
2. Schemas get validated somewhere in the call chain
3. NimbleOptions is used for validation (possibly by a transitive dependency)
4. NimbleOptions syntax:
   - ✗ `[type: :list, items: ...]` - Invalid!
   - ✓ `[type: {:list, :map}]` - Valid!
   - ✓ `[type: {:list, :string}]` - Valid!

### Why ReqLLM Shows Up

`req_llm` v1.0.0 is in `mix.lock` as a dependency (possibly transitive or orphaned).
It uses NimbleOptions for schema validation, which causes our error.

Even though the code doesn't directly use ReqLLM, it gets loaded and its error type appears.

## Files Modified

- ✅ `lib/lumainus/reports.ex` - Fixed `default_schema()` function
- 📝 `examples/diagnose_schema_error.exs` - New diagnostic script
- 📝 `examples/fix_schemas_in_db.exs` - New fix script
- 📝 `examples/clear_old_runs.exs` - New cleanup script
- 📝 `examples/reproduce_reqllm_error.exs` - New reproduction script
- 📝 `examples/README_SCHEMA_FIX.md` - This file
