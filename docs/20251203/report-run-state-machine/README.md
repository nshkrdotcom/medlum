# Report Run State Machine Improvements

**Date:** 2025-12-03
**Status:** Proposed
**Author:** Claude (with user guidance)

## Problem Statement

Report runs can become stuck in `"running"` status when:

1. **Race conditions** in distributed state finalization - multiple Oban workers update the same `report_run` concurrently using stale struct data
2. **Missing recovery** for edge cases - jobs that crash after marking section as "running" but before calling finalize leave orphan state
3. **No timeout mechanism** - runs have no deadline and can remain "running" indefinitely
4. **Distributed state logic** - each worker independently tries to finalize; works for happy paths but fragile when jobs overlap or fail

### Evidence

Investigation of stuck run `f0fa411a`:
- Report run status: `running`
- Section runs: 5 `completed`, 8 `error` (rate limited by Gemini)
- All sections finished processing, but run was never finalized

---

## Current Implementation Analysis

### Status Values (Match Existing)

| Entity | Valid Statuses |
|--------|----------------|
| `report_runs` | `pending`, `queued`, `running`, `completed`, `error`, `timed_out` (new) |
| `report_section_runs` | `pending`, `queued`, `running`, `completed`, `error`, `timed_out` (new) |

### Current Flow (`section_run_worker.ex`)

```elixir
def perform(%Oban.Job{args: %{"section_run_id" => section_run_id}}) do
  section_run = Repo.get!(ReportSectionRun, section_run_id) |> Repo.preload(...)
  report_run = ensure_run_running(section_run.report_run)  # ← Loads at job start

  result = SectionRunner.run_section(scope, section_run, patient, documents)

  finalize_run_state(report_run, result)  # ← Uses potentially stale report_run
  ...
end
```

### Race Condition

```
Time →
Job A: Load run → SectionRunner → finalize_run_state(stale_run, :ok)
Job B: Load run → SectionRunner → finalize_run_state(stale_run, :error)
Job C: Load run → SectionRunner → finalize_run_state(stale_run, :ok)
                                                    ↓
                                   Last write wins, no atomicity
```

---

## Proposed Solution

### 1. Schema Changes (Migration)

Add fields to `report_runs` table:

```elixir
alter table(:report_runs) do
  add :timeout_at, :utc_datetime      # Hard deadline (started_at + 30 min)
  add :last_activity_at, :utc_datetime # Updated on each section state change
end
```

**Design Decisions:**
- `timeout_at` set at run creation: `DateTime.add(now, 30, :minute)` (configurable)
- `last_activity_at` set at run start AND each section completion/error
- Allows staleness checker to distinguish "actively running" from "stuck"

### 2. Centralized State Reconciler

Create `Medlum.Reports.RunReconciler` module:

```elixir
defmodule Medlum.Reports.RunReconciler do
  @moduledoc """
  Atomic state reconciliation for report runs.

  Avoids race conditions by using row-level locking and
  always fetching fresh section statuses within transaction.
  """

  import Ecto.Query
  alias Medlum.Repo
  alias Medlum.Reports.{ReportRun, ReportSectionRun}

  @doc """
  Atomically check and finalize a report run if all sections are done.

  Uses FOR UPDATE lock to prevent concurrent modifications.
  Idempotent: no-op if already finalized.
  """
  def maybe_finalize(report_run_id) do
    Repo.transaction(fn ->
      # Lock the row to prevent concurrent updates
      run =
        ReportRun
        |> where([r], r.id == ^report_run_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if run.status in ["running", "pending", "queued"] do
        section_statuses = fetch_section_statuses(report_run_id)
        now = DateTime.utc_now(:second)

        case compute_final_status(section_statuses) do
          nil ->
            # Still in progress - bump activity timestamp
            Repo.update!(Ecto.Changeset.change(run, %{last_activity_at: now}))

          final_status ->
            Repo.update!(Ecto.Changeset.change(run, %{
              status: final_status,
              finished_at: now,
              last_activity_at: now
            }))
        end
      else
        # Already finalized, no-op
        run
      end
    end)
  end

  @doc """
  Mark a run as timed out, including any running/pending sections.
  """
  def mark_timed_out(report_run_id) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      run =
        ReportRun
        |> where([r], r.id == ^report_run_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if run.status in ["running", "pending", "queued"] do
        # Mark all incomplete sections as timed_out
        ReportSectionRun
        |> where([s], s.report_run_id == ^report_run_id)
        |> where([s], s.status in ["pending", "queued", "running"])
        |> Repo.update_all(set: [status: "timed_out", updated_at: now])

        # Mark run as timed_out
        Repo.update!(Ecto.Changeset.change(run, %{
          status: "timed_out",
          finished_at: now,
          last_activity_at: now
        }))
      else
        run
      end
    end)
  end

  # Fetch statuses directly from DB (fresh, not from struct)
  defp fetch_section_statuses(report_run_id) do
    ReportSectionRun
    |> where([s], s.report_run_id == ^report_run_id)
    |> select([s], s.status)
    |> Repo.all()
  end

  # Determine final status based on all section statuses
  # Returns nil if still in progress (sections not all done)
  defp compute_final_status(statuses) do
    cond do
      # Any section still processing → not done yet
      Enum.any?(statuses, &(&1 in ["pending", "queued", "running"])) ->
        nil

      # All done, any errors → error
      Enum.any?(statuses, &(&1 in ["error", "timed_out"])) ->
        "error"

      # All completed successfully
      Enum.all?(statuses, &(&1 == "completed")) ->
        "completed"

      # Unexpected state (empty sections, unknown status)
      true ->
        "error"
    end
  end
end
```

**Key Properties:**
- **Atomic**: Uses `FOR UPDATE` row lock within transaction
- **Idempotent**: No-op if already finalized
- **Fresh data**: Always fetches section statuses inside transaction
- **Consistent**: Marks both run and sections as `timed_out` together

### 3. Periodic Staleness Checker (Oban Cron)

Create `Medlum.Reports.StaleRunWorker`:

```elixir
defmodule Medlum.Reports.StaleRunWorker do
  @moduledoc """
  Oban cron worker that detects and fixes stale report runs.

  Runs every 5 minutes to:
  1. Find runs past timeout_at → mark as timed_out
  2. Find runs where all sections done but run still "running" → finalize
  3. Find runs inactive for 10+ minutes → investigate/timeout
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query
  alias Medlum.Repo
  alias Medlum.Reports.{ReportRun, ReportSectionRun, RunReconciler}

  @stale_activity_minutes 10

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    # 1. Find runs past their timeout
    timed_out_runs = find_past_timeout(now)
    Enum.each(timed_out_runs, &RunReconciler.mark_timed_out(&1.id))

    # 2. Find "running" runs where all sections are done but run wasn't finalized
    orphaned_runs = find_orphaned_running(now)
    Enum.each(orphaned_runs, &RunReconciler.maybe_finalize(&1.id))

    # 3. Find runs with stale activity (no section progress for 10+ min)
    stale_runs = find_stale_activity(now)
    Enum.each(stale_runs, &RunReconciler.mark_timed_out(&1.id))

    :ok
  end

  defp find_past_timeout(now) do
    ReportRun
    |> where([r], r.status in ["running", "pending", "queued"])
    |> where([r], not is_nil(r.timeout_at) and r.timeout_at < ^now)
    |> Repo.all()
  end

  defp find_orphaned_running(now) do
    # Runs that are "running" but have no pending/queued/running sections
    running_run_ids =
      ReportRun
      |> where([r], r.status == "running")
      |> select([r], r.id)
      |> Repo.all()

    # Filter to only those where ALL sections are terminal
    Enum.filter(running_run_ids, fn run_id ->
      active_count =
        ReportSectionRun
        |> where([s], s.report_run_id == ^run_id)
        |> where([s], s.status in ["pending", "queued", "running"])
        |> Repo.aggregate(:count)

      active_count == 0
    end)
    |> Enum.map(&%{id: &1})
  end

  defp find_stale_activity(now) do
    stale_threshold = DateTime.add(now, -@stale_activity_minutes, :minute)

    ReportRun
    |> where([r], r.status == "running")
    |> where([r], not is_nil(r.last_activity_at) and r.last_activity_at < ^stale_threshold)
    |> Repo.all()
  end
end
```

**Add to Oban crontab** in `config/config.exs`:

```elixir
{Oban.Plugins.Cron,
 crontab: [
   {"*/15 * * * *", Medlum.Documents.IngestionCleanupWorker},
   {"*/5 * * * *", Medlum.Reports.StaleRunWorker}  # NEW
 ]}
```

### 4. Update SectionRunWorker

Replace distributed `finalize_run_state` with atomic reconciler:

```elixir
defmodule Medlum.Reports.SectionRunWorker do
  # ... existing code ...

  alias Medlum.Reports.RunReconciler

  @impl true
  def perform(%Oban.Job{args: %{"section_run_id" => section_run_id}}) do
    section_run =
      ReportSectionRun
      |> Repo.get!(section_run_id)
      |> Repo.preload([
        :section_template,
        report_run: [:template, :patient, :record_set]
      ])

    report_run = ensure_run_running(section_run.report_run)
    # ... existing setup code ...

    result = SectionRunner.run_section(scope, section_run, patient, documents)

    # Use atomic reconciler instead of distributed finalize
    RunReconciler.maybe_finalize(report_run.id)

    Reports.notify_section_run_update(report_run.record_set_id)

    case result do
      {:ok, _run} -> :ok
      {:error, _run} -> :ok
    end
  end

  defp ensure_run_running(%ReportRun{} = report_run) do
    if report_run.status in ["queued", "pending"] do
      now = DateTime.utc_now(:second)

      Repo.update!(
        Ecto.Changeset.change(report_run, %{
          status: "running",
          started_at: now,
          last_activity_at: now  # NEW: Set on run start
        })
      )
    else
      report_run
    end
  end

  # REMOVE: finalize_run_state/2 - replaced by RunReconciler
end
```

### 5. Update `run_sections/6` in Reports

Set `timeout_at` at run creation:

```elixir
def run_sections(%Scope{} = scope, patient, record_set, template, section_ids, opts \\ []) do
  # ... existing code ...

  now = DateTime.utc_now(:second)
  timeout_minutes = Keyword.get(opts, :timeout_minutes, 30)
  timeout_at = DateTime.add(now, timeout_minutes, :minute)

  run =
    %ReportRun{}
    |> ReportRun.changeset(%{
      tenant_id: tenant_id,
      patient_id: patient.id,
      record_set_id: record_set.id,
      template_id: template.id,
      run_type: run_type_for(sections, template),
      status: "queued",
      triggered_by_user_id: scope.user && scope.user.id,
      timeout_at: timeout_at,           # NEW
      last_activity_at: now             # NEW
    })
    |> Repo.insert!()

  # ... rest of function ...
end
```

---

## Migration

```elixir
defmodule Medlum.Repo.Migrations.AddReportRunTimeoutFields do
  use Ecto.Migration

  def change do
    alter table(:report_runs) do
      add :timeout_at, :utc_datetime
      add :last_activity_at, :utc_datetime
    end

    # Index for staleness queries
    create index(:report_runs, [:status, :timeout_at])
    create index(:report_runs, [:status, :last_activity_at])
  end
end
```

### Backfill Migration

```elixir
defmodule Medlum.Repo.Migrations.BackfillReportRunTimeouts do
  use Ecto.Migration

  def up do
    # Set timeout_at for existing runs with started_at
    # Uses 30 minute timeout from started_at
    execute """
      UPDATE report_runs
      SET timeout_at = started_at + interval '30 minutes',
          last_activity_at = COALESCE(finished_at, started_at, inserted_at)
      WHERE started_at IS NOT NULL
        AND timeout_at IS NULL
    """

    # For runs without started_at, use inserted_at
    execute """
      UPDATE report_runs
      SET timeout_at = inserted_at + interval '30 minutes',
          last_activity_at = COALESCE(finished_at, inserted_at)
      WHERE started_at IS NULL
        AND timeout_at IS NULL
    """

    # Fix currently stuck runs (running for 30+ minutes)
    execute """
      UPDATE report_runs
      SET status = 'timed_out',
          finished_at = NOW()
      WHERE status = 'running'
        AND started_at < NOW() - interval '30 minutes'
    """

    # Also mark orphan section runs
    execute """
      UPDATE report_section_runs
      SET status = 'timed_out'
      WHERE status IN ('pending', 'queued', 'running')
        AND report_run_id IN (
          SELECT id FROM report_runs WHERE status = 'timed_out'
        )
    """
  end

  def down do
    # Revert timed_out to error (close enough)
    execute """
      UPDATE report_runs SET status = 'error' WHERE status = 'timed_out'
    """
    execute """
      UPDATE report_section_runs SET status = 'error' WHERE status = 'timed_out'
    """
  end
end
```

---

## Implementation Checklist

- [ ] Create migration for schema changes (`timeout_at`, `last_activity_at`)
- [ ] Create backfill migration
- [ ] Update `ReportRun` schema with new fields
- [ ] Create `RunReconciler` module
- [ ] Create `StaleRunWorker` Oban worker
- [ ] Add worker to Oban crontab
- [ ] Update `SectionRunWorker` to use `RunReconciler`
- [ ] Update `Reports.run_sections/6` to set timeout fields
- [ ] Add tests for reconciler edge cases
- [ ] Add tests for staleness checker

---

## Testing Strategy

### Unit Tests

1. `RunReconciler.maybe_finalize/1`
   - All sections completed → run becomes "completed"
   - Any section error → run becomes "error"
   - Some sections still pending → run stays "running", bumps activity
   - Already finalized → no-op

2. `RunReconciler.mark_timed_out/1`
   - Running run → becomes "timed_out"
   - All incomplete sections → become "timed_out"
   - Already finalized → no-op

### Integration Tests

1. Concurrent section completion
   - Spawn multiple processes calling `maybe_finalize` simultaneously
   - Assert exactly one final status update

2. Staleness detection
   - Create run, don't process sections
   - Verify `StaleRunWorker` marks it as timed_out after threshold

---

## Configuration

Add to `config/config.exs` (optional, for tuning):

```elixir
config :medlum, :report_runs,
  default_timeout_minutes: 30,
  stale_activity_minutes: 10,
  staleness_check_interval: "*/5 * * * *"
```

---

## Rollback Strategy

If issues arise:

1. Disable `StaleRunWorker` in crontab
2. Revert `SectionRunWorker` to use old `finalize_run_state`
3. Migration `down` converts `timed_out` → `error`

The schema changes are additive (new columns) and don't break existing code.
