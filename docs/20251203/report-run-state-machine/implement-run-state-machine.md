# Implement Report Run State Machine Improvements

## Overview

Implement a robust state machine for report runs that handles race conditions, timeouts, and stuck states. The current implementation has race conditions where concurrent Oban workers can leave runs stuck in "running" status.

---

## Required Reading

Before starting, read these files to understand the current implementation:

### Design Document (READ FIRST)
- `/home/home/p/g/n/lumainus/docs/20251203/report-run-state-machine/README.md` - Complete design spec with code examples

### Current Implementation
- `/home/home/p/g/n/lumainus/lib/lumainus/reports/report_run.ex` - ReportRun schema
- `/home/home/p/g/n/lumainus/lib/lumainus/reports/report_section_run.ex` - ReportSectionRun schema
- `/home/home/p/g/n/lumainus/lib/lumainus/reports/section_run_worker.ex` - Current Oban worker with race condition
- `/home/home/p/g/n/lumainus/lib/lumainus/reports.ex` - Reports context, especially `run_sections/6` function (around line 237)

### Configuration
- `/home/home/p/g/n/lumainus/config/config.exs` - Oban crontab config (around line 126)

### Existing Patterns to Follow
- `/home/home/p/g/n/lumainus/lib/lumainus/documents/ingestion_cleanup_worker.ex` - Example Oban cron worker pattern
- `/home/home/p/g/n/lumainus/lib/lumainus/conversion/job.ex` - Example of timeout_at pattern in schema

---

## Implementation Tasks (TDD Approach)

### Task 1: Schema Migration

**File:** `priv/repo/migrations/YYYYMMDDHHMMSS_add_report_run_timeout_fields.exs`

Create migration adding:
- `timeout_at` (`:utc_datetime`) - Hard deadline for run completion
- `last_activity_at` (`:utc_datetime`) - Updated on each section state change
- Indexes on `[:status, :timeout_at]` and `[:status, :last_activity_at]`

### Task 2: Backfill Migration

**File:** `priv/repo/migrations/YYYYMMDDHHMMSS_backfill_report_run_timeouts.exs`

Backfill existing data:
1. Set `timeout_at = started_at + 30 minutes` for runs with `started_at`
2. Set `last_activity_at = COALESCE(finished_at, started_at, inserted_at)`
3. Fix stuck runs: mark as `timed_out` if `status = 'running'` AND `started_at < NOW() - 30 minutes`
4. Mark orphan section_runs as `timed_out` where parent run is `timed_out`

### Task 3: Update ReportRun Schema

**File:** `/home/home/p/g/n/lumainus/lib/lumainus/reports/report_run.ex`

Add fields:
```elixir
field(:timeout_at, :utc_datetime)
field(:last_activity_at, :utc_datetime)
```

Update changeset to cast these fields.

### Task 4: Create RunReconciler Module (TDD)

**File:** `/home/home/p/g/n/lumainus/lib/lumainus/reports/run_reconciler.ex`
**Test:** `/home/home/p/g/n/lumainus/test/lumainus/reports/run_reconciler_test.exs`

Write tests FIRST for:

```elixir
# Test cases for maybe_finalize/1
describe "maybe_finalize/1" do
  test "marks run as completed when all sections completed"
  test "marks run as error when any section has error"
  test "marks run as error when any section timed_out"
  test "bumps last_activity_at when sections still pending"
  test "no-op when run already completed"
  test "no-op when run already error"
  test "handles concurrent calls safely" # spawn multiple processes
end

# Test cases for mark_timed_out/1
describe "mark_timed_out/1" do
  test "marks running run as timed_out"
  test "marks all pending/running sections as timed_out"
  test "no-op when run already finalized"
end
```

Implementation must:
- Use `Repo.transaction` with `lock: "FOR UPDATE"`
- Fetch fresh section statuses inside transaction
- Be idempotent (no-op if already finalized)

### Task 5: Create StaleRunWorker (TDD)

**File:** `/home/home/p/g/n/lumainus/lib/lumainus/reports/stale_run_worker.ex`
**Test:** `/home/home/p/g/n/lumainus/test/lumainus/reports/stale_run_worker_test.exs`

Write tests FIRST for:

```elixir
describe "perform/1" do
  test "marks runs past timeout_at as timed_out"
  test "finalizes orphaned running runs (all sections done)"
  test "marks runs with stale activity as timed_out"
  test "ignores already finalized runs"
end
```

Implementation:
- `use Oban.Worker, queue: :maintenance, max_attempts: 1`
- Find runs past `timeout_at`
- Find "running" runs where all sections are terminal but run wasn't finalized
- Find runs with `last_activity_at` older than 10 minutes

### Task 6: Add to Oban Crontab

**File:** `/home/home/p/g/n/lumainus/config/config.exs`

Add to existing crontab:
```elixir
{"*/5 * * * *", Lumainus.Reports.StaleRunWorker}
```

### Task 7: Update SectionRunWorker

**File:** `/home/home/p/g/n/lumainus/lib/lumainus/reports/section_run_worker.ex`

Changes:
1. Remove `finalize_run_state/2` function entirely
2. Replace call with `RunReconciler.maybe_finalize(report_run.id)`
3. Update `ensure_run_running/1` to also set `last_activity_at: now`
4. Add `alias Lumainus.Reports.RunReconciler`

### Task 8: Update Reports.run_sections/6

**File:** `/home/home/p/g/n/lumainus/lib/lumainus/reports.ex`

In `run_sections/6` (around line 248-260), update run creation:

```elixir
now = DateTime.utc_now(:second)
timeout_minutes = Keyword.get(opts, :timeout_minutes, 30)
timeout_at = DateTime.add(now, timeout_minutes, :minute)

run =
  %ReportRun{}
  |> ReportRun.changeset(%{
    # ... existing fields ...
    timeout_at: timeout_at,
    last_activity_at: now
  })
  |> Repo.insert!()
```

---

## Verification Steps

After implementation, verify:

1. **Migrations run cleanly:**
   ```bash
   mix ecto.migrate
   ```

2. **All tests pass:**
   ```bash
   mix test test/lumainus/reports/run_reconciler_test.exs
   mix test test/lumainus/reports/stale_run_worker_test.exs
   mix test test/lumainus/reports/
   ```

3. **No compilation warnings:**
   ```bash
   mix compile --warnings-as-errors
   ```

4. **Dialyzer passes:**
   ```bash
   mix dialyzer
   ```

5. **Credo clean:**
   ```bash
   mix credo --strict
   ```

6. **Server starts:**
   ```bash
   mix phx.server
   ```

---

## Status Values Reference

| Entity | Valid Statuses |
|--------|----------------|
| `report_runs` | `pending`, `queued`, `running`, `completed`, `error`, `timed_out` |
| `report_section_runs` | `pending`, `queued`, `running`, `completed`, `error`, `timed_out` |

---

## Key Design Constraints

1. **Atomic operations** - All status changes must use `FOR UPDATE` locks
2. **Idempotent** - `maybe_finalize` and `mark_timed_out` must be safe to call multiple times
3. **Consistent** - When timing out, mark BOTH run AND sections as `timed_out`
4. **Match existing patterns** - Follow code style in existing files
5. **No compilation warnings** - All code must compile cleanly

---

## Notes

- Migration timestamps should use current time (e.g., `20251203120000`)
- The `timed_out` status is NEW - it will be used for the first time
- Keep transactions small to avoid contention
- The 30-minute timeout and 10-minute stale threshold are hardcoded for now (can be made configurable later)
