# Docling Ingestion Queue System - Technical Design

## Overview

This document analyzes the current ingestion queue system, identifies issues with timeout handling and job management, and proposes a robust, testable architecture with cleanup and self-healing mechanisms.

## Table of Contents

1. [Current State Analysis](#current-state-analysis)
2. [Timeout Flow Analysis](#timeout-flow-analysis)
3. [Identified Issues](#identified-issues)
4. [Proposed Architecture](#proposed-architecture)
5. [Test Strategy](#test-strategy)
6. [Implementation Plan](#implementation-plan)

---

## Current State Analysis

### Component Overview

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  ReportsLive    │────▶│  Oban Worker     │────▶│  Docling Queue  │
│  (UI/Upload)    │     │  (max_attempts:5)│     │  (SSE/Polling)  │
└─────────────────┘     └──────────────────┘     └─────────────────┘
        │                        │                        │
        │                        ▼                        │
        │               ┌──────────────────┐              │
        └──────────────▶│ IngestionProcessor│◀─────────────┘
                        │ (orchestration)   │
                        └──────────────────┘
                                 │
                        ┌────────┴────────┐
                        ▼                 ▼
               ┌──────────────┐   ┌──────────────────┐
               │IngestionJob  │   │ DocumentUpload   │
               │(DB record)   │   │ (metadata)       │
               └──────────────┘   └──────────────────┘
```

### Current Timeout Configuration

| Component | Setting | Value | Location |
|-----------|---------|-------|----------|
| Python Service | `_conversion_timeout` | 1200s (20 min) | `docling_service/app/main.py:46` |
| Elixir Default | `Docling.timeout()` | 1,200,000ms (20 min) | `lib/medlum/docling.ex:138` |
| Config Override | `request_timeout` | 1,200,000ms (20 min) | `config/config.exs:29` |
| Oban Worker | `max_attempts` | 5 | `docling_ingestion_worker.ex:6` |

### Data Flow

1. **Upload Phase**:
   - User uploads PDF via ReportsLive
   - `Documents.create_upload/5` creates DocumentUpload record
   - `Documents.queue_ingestion/2` creates IngestionJob + Oban job

2. **Processing Phase**:
   - Oban dispatches `DoclingIngestionWorker.perform/1`
   - `IngestionProcessor.process/1` orchestrates:
     - Marks job as processing
     - Calls `DoclingQueue.enqueue/2` with `timeout_ms`
     - `DoclingQueue.await/2` waits for SSE events
     - Progress events forwarded via `on_status` callback
     - Result persisted to DocumentParse

3. **Timeout Handling (Current)**:
   - Queue sets `timeout_at = now + timeout_ms`
   - Python service has independent `_conversion_timeout`
   - On timeout: Elixir returns `{:error, :timeout}`
   - Oban retries the job (up to 5 times)
   - Each retry resets `timeout_at`

---

## Timeout Flow Analysis

### The "5 Minute Countdown Reset" Bug

**Symptom**: UI shows countdown, expires, then restarts.

**Root Cause**:

```elixir
# docling_ingestion_worker.ex
use Oban.Worker, queue: :ingestion, max_attempts: 5

def perform(%Oban.Job{args: %{"ingestion_job_id" => job_id}}) do
  case IngestionProcessor.process(job_id) do
    :ok -> :ok
    {:error, _reason} -> {:error, :ingestion_failed}  # Triggers Oban retry
  end
end
```

When timeout occurs:
1. `Queue.await/2` returns `{:error, :timeout}`
2. `IngestionProcessor.process/1` returns `{:error, reason}`
3. Worker returns `{:error, :ingestion_failed}`
4. Oban schedules retry with exponential backoff
5. New attempt calls `mark_processing/1` which updates `timeout_at`
6. UI countdown resets

### Timeout Coordination Issues

1. **Two Independent Timers**:
   - Python: `asyncio.wait_for(..., timeout=_conversion_timeout)`
   - Elixir: `Queue.await/2` deadline based on `timeout_ms`

2. **No Cancellation**:
   - If Elixir times out first, Python job continues running
   - If Python times out first, Elixir may wait forever (until its deadline)

3. **Stale Job Accumulation**:
   - Failed jobs remain in `JOB_STORE` on Python side
   - DB records accumulate with `state: "failed"`
   - No cleanup of orphaned resources

---

## Identified Issues

### Critical Issues

1. **Timeout Mismatch**: Elixir and Python timeouts can race
2. **Retry Storm**: 5 Oban retries × 20 min = 100 min total before giving up
3. **No Job Cancellation**: Can't stop a running Docling conversion
4. **Resource Leaks**: Failed jobs leave temp files, memory

### Data Integrity Issues

1. **Orphaned Records**: IngestionJob without corresponding Oban job
2. **Stale States**: Jobs stuck in "processing" indefinitely
3. **Duplicate Attempts**: Same upload queued multiple times
4. **No Idempotency**: Retries may create duplicate DocumentParse records

### Observability Issues

1. **No Health Metrics**: Can't see queue depth, processing times
2. **Poor Error Context**: Generic "ingestion_failed" error
3. **Missing Audit Trail**: No record of retry attempts

---

## Proposed Architecture

### 1. Unified Timeout Management

```elixir
# New module: lib/medlum/documents/ingestion_config.ex
defmodule Medlum.Documents.IngestionConfig do
  @moduledoc """
  Centralized configuration for ingestion timeouts and limits.
  """

  # Single source of truth for all timeouts
  def conversion_timeout_ms do
    Application.get_env(:medlum, :ingestion, [])
    |> Keyword.get(:conversion_timeout_ms, 1_200_000)  # 20 min
  end

  def max_retries, do: 3  # Reduced from 5

  def retry_backoff_ms(attempt) do
    # Exponential backoff: 30s, 60s, 120s
    min(30_000 * :math.pow(2, attempt - 1), 300_000)
  end

  def max_file_size_bytes, do: 50_000_000  # 50 MB

  def max_pages, do: 1000

  def stale_job_threshold_minutes, do: 60
end
```

### 2. Job State Machine

```
                    ┌──────────┐
                    │ pending  │
                    └────┬─────┘
                         │ queue_ingestion
                         ▼
                    ┌──────────┐
              ┌────▶│ queued   │◀────┐
              │     └────┬─────┘     │
              │          │ worker picks up
              │          ▼           │
              │     ┌──────────┐     │
              │     │processing│─────┤ timeout/error
              │     └────┬─────┘     │ (if retries left)
              │          │           │
              │     ┌────┴────┐      │
              │     ▼         ▼      │
         ┌──────────┐   ┌──────────┐ │
         │completed │   │  failed  │─┘
         └──────────┘   └──────────┘
              │               │
              └───────┬───────┘
                      │ (after TTL)
                      ▼
                 ┌──────────┐
                 │ archived │
                 └──────────┘
```

### 3. Enhanced Job Record

```elixir
# Add to IngestionJob schema
field(:attempt_number, :integer, default: 1)
field(:max_attempts, :integer, default: 3)
field(:next_retry_at, :utc_datetime)
field(:deadline_at, :utc_datetime)  # Hard deadline across all retries
field(:cancelled_at, :utc_datetime)
field(:archived_at, :utc_datetime)
field(:error_history, {:array, :map}, default: [])
```

### 4. Improved Worker with Circuit Breaker

```elixir
defmodule Medlum.Documents.DoclingIngestionWorker do
  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 3,
    priority: 1

  alias Medlum.Documents.{IngestionProcessor, IngestionConfig, IngestionJob}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ingestion_job_id" => job_id}, attempt: attempt}) do
    job = Repo.get!(IngestionJob, job_id)

    # Check if job should be retried
    cond do
      job.cancelled_at ->
        {:cancel, :job_cancelled}

      job.deadline_at && DateTime.compare(DateTime.utc_now(), job.deadline_at) == :gt ->
        mark_job_failed(job, "Hard deadline exceeded")
        {:cancel, :deadline_exceeded}

      attempt > job.max_attempts ->
        mark_job_failed(job, "Max attempts exceeded")
        {:cancel, :max_attempts_exceeded}

      true ->
        process_with_timeout(job, attempt)
    end
  end

  defp process_with_timeout(job, attempt) do
    timeout = IngestionConfig.conversion_timeout_ms()

    # Update job with attempt info
    update_job_attempt(job, attempt, timeout)

    task = Task.async(fn -> IngestionProcessor.process(job.id) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        record_error(job, attempt, reason)
        {:error, reason}

      nil ->
        record_error(job, attempt, :timeout)
        {:error, :timeout}
    end
  end

  defp record_error(job, attempt, reason) do
    error_entry = %{
      attempt: attempt,
      reason: inspect(reason),
      timestamp: DateTime.utc_now()
    }

    job
    |> Changeset.change(%{
      error_history: job.error_history ++ [error_entry],
      last_error: inspect(reason)
    })
    |> Repo.update!()
  end
end
```

### 5. Job Cancellation Support

```elixir
# Add to Documents module
def cancel_ingestion_job(job_id) do
  job = Repo.get!(IngestionJob, job_id)

  # Mark job as cancelled
  job
  |> Changeset.change(%{
    cancelled_at: DateTime.utc_now(),
    state: "failed",
    last_error: "Cancelled by user"
  })
  |> Repo.update!()

  # Cancel Oban job
  Oban.cancel_job(job.oban_job_id)

  # Notify Python service (optional - if we add cancellation endpoint)
  # Docling.cancel_job(job.docling_job_id)

  :ok
end
```

### 6. Cleanup Worker

```elixir
defmodule Medlum.Documents.IngestionCleanupWorker do
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  alias Medlum.Documents.{IngestionJob, IngestionConfig}

  @impl Oban.Worker
  def perform(_job) do
    cleanup_stale_jobs()
    archive_old_completed_jobs()
    cleanup_orphaned_uploads()
    :ok
  end

  defp cleanup_stale_jobs do
    threshold = IngestionConfig.stale_job_threshold_minutes()
    cutoff = DateTime.add(DateTime.utc_now(), -threshold, :minute)

    # Find jobs stuck in processing
    stale_jobs =
      IngestionJob
      |> where([j], j.state == "processing")
      |> where([j], j.updated_at < ^cutoff)
      |> Repo.all()

    Enum.each(stale_jobs, fn job ->
      job
      |> Changeset.change(%{
        state: "failed",
        last_error: "Marked stale by cleanup worker",
        finished_at: DateTime.utc_now()
      })
      |> Repo.update!()

      # Notify UI
      Documents.notify_job_progress(job)
    end)

    Logger.info("Cleaned up #{length(stale_jobs)} stale ingestion jobs")
  end

  defp archive_old_completed_jobs do
    # Archive completed/failed jobs older than 7 days
    cutoff = DateTime.add(DateTime.utc_now(), -7, :day)

    {count, _} =
      IngestionJob
      |> where([j], j.state in ["completed", "failed"])
      |> where([j], is_nil(j.archived_at))
      |> where([j], j.finished_at < ^cutoff)
      |> Repo.update_all(set: [archived_at: DateTime.utc_now()])

    Logger.info("Archived #{count} old ingestion jobs")
  end

  defp cleanup_orphaned_uploads do
    # Find uploads without any ingestion jobs
    # (shouldn't happen, but defensive)
    cutoff = DateTime.add(DateTime.utc_now(), -1, :hour)

    orphaned =
      DocumentUpload
      |> where([u], u.status == "pending")
      |> where([u], u.inserted_at < ^cutoff)
      |> where([u], fragment("NOT EXISTS (SELECT 1 FROM ingestion_jobs WHERE upload_id = ?)", u.id))
      |> Repo.all()

    Enum.each(orphaned, fn upload ->
      upload
      |> Changeset.change(%{
        status: "failed",
        metadata: Map.put(upload.metadata || %{}, "error", "Orphaned upload")
      })
      |> Repo.update!()
    end)

    Logger.info("Cleaned up #{length(orphaned)} orphaned uploads")
  end
end
```

### 7. Self-Healing Mechanisms

```elixir
defmodule Medlum.Documents.IngestionHealthChecker do
  use GenServer

  @check_interval_ms 60_000  # 1 minute

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    schedule_check()
    {:ok, %{}}
  end

  def handle_info(:check_health, state) do
    check_and_heal()
    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check_health, @check_interval_ms)
  end

  defp check_and_heal do
    # 1. Check for stuck jobs
    heal_stuck_jobs()

    # 2. Check Docling service health
    check_docling_health()

    # 3. Reconcile job states
    reconcile_job_states()
  end

  defp heal_stuck_jobs do
    # Jobs in "processing" but no Oban job running
    stuck =
      IngestionJob
      |> where([j], j.state == "processing")
      |> where([j], j.updated_at < ^DateTime.add(DateTime.utc_now(), -10, :minute))
      |> Repo.all()

    Enum.each(stuck, fn job ->
      # Check if Oban job exists and is running
      case Oban.Job |> where([o], o.id == ^job.oban_job_id) |> Repo.one() do
        nil ->
          # Oban job gone - requeue
          Documents.retry_ingestion(job.upload_id)

        %{state: "completed"} ->
          # Oban thinks it's done but our record says processing
          # This is a bug - investigate
          Logger.error("State mismatch: IngestionJob #{job.id} processing but Oban completed")

        %{state: "discarded"} ->
          # Oban gave up - mark our job failed
          job
          |> Changeset.change(%{state: "failed", last_error: "Oban job discarded"})
          |> Repo.update!()

        _ ->
          # Oban job still running - OK
          :ok
      end
    end)
  end

  defp check_docling_health do
    case Docling.health_check() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Docling health check failed: #{inspect(reason)}")
        # Could pause queue here if needed
    end
  end

  defp reconcile_job_states do
    # Ensure DB state matches Oban state
    # This catches edge cases from crashes/restarts
  end
end
```

---

## Test Strategy

### 1. Unit Tests - Isolated Components

```elixir
# test/medlum/documents/ingestion_config_test.exs
defmodule Medlum.Documents.IngestionConfigTest do
  use ExUnit.Case

  test "conversion_timeout_ms returns configured value" do
    assert IngestionConfig.conversion_timeout_ms() == 1_200_000
  end

  test "retry_backoff_ms calculates exponential backoff" do
    assert IngestionConfig.retry_backoff_ms(1) == 30_000
    assert IngestionConfig.retry_backoff_ms(2) == 60_000
    assert IngestionConfig.retry_backoff_ms(3) == 120_000
  end
end
```

### 2. Integration Tests - Database Flow

```elixir
# test/medlum/documents/ingestion_job_lifecycle_test.exs
defmodule Medlum.Documents.IngestionJobLifecycleTest do
  use Medlum.DataCase

  alias Medlum.Documents
  alias Medlum.Documents.{IngestionJob, DocumentUpload}

  describe "job lifecycle" do
    setup do
      # Create test tenant, patient, record_set
      {:ok, scope: scope, patient: patient, record_set: record_set}
    end

    test "creates job with correct initial state", ctx do
      {:ok, upload} = create_test_upload(ctx)
      {:ok, job} = Documents.queue_ingestion(upload)

      assert job.state == "queued"
      assert job.stage == "queued"
      assert job.attempt_number == 1
      assert job.max_attempts == 3
      assert job.deadline_at != nil
    end

    test "job transitions through states correctly", ctx do
      {:ok, upload} = create_test_upload(ctx)
      {:ok, job} = Documents.queue_ingestion(upload)

      # Simulate worker pickup
      {:ok, job} = Documents.mark_job_processing(job)
      assert job.state == "processing"

      # Simulate completion
      {:ok, job} = Documents.mark_job_completed(job)
      assert job.state == "completed"
    end

    test "job records error history on failure", ctx do
      {:ok, upload} = create_test_upload(ctx)
      {:ok, job} = Documents.queue_ingestion(upload)

      {:ok, job} = Documents.record_job_error(job, 1, :timeout)

      assert length(job.error_history) == 1
      assert hd(job.error_history).reason == ":timeout"
    end

    test "cancellation stops job", ctx do
      {:ok, upload} = create_test_upload(ctx)
      {:ok, job} = Documents.queue_ingestion(upload)

      :ok = Documents.cancel_ingestion_job(job.id)

      job = Repo.get!(IngestionJob, job.id)
      assert job.cancelled_at != nil
      assert job.state == "failed"
    end
  end
end
```

### 3. Integration Tests - Full Pipeline with Real PDF

```elixir
# test/medlum/documents/ingestion_integration_test.exs
defmodule Medlum.Documents.IngestionIntegrationTest do
  use Medlum.DataCase, async: false

  @moduletag :integration
  @moduletag timeout: 300_000  # 5 min timeout for real conversion

  alias Medlum.Documents

  setup do
    # Ensure Docling service is running
    case Docling.health_check() do
      {:ok, _} -> :ok
      {:error, _} -> skip("Docling service not available")
    end

    {:ok, scope: create_test_scope()}
  end

  describe "full ingestion pipeline" do
    @tag :slow
    test "successfully ingests small PDF", ctx do
      # Use a small test PDF (1-2 pages)
      pdf_path = Path.join(__DIR__, "../fixtures/small_test.pdf")
      pdf_binary = File.read!(pdf_path)

      {:ok, upload} = Documents.create_upload(
        ctx.scope,
        ctx.patient,
        ctx.record_set,
        %{filename: "test.pdf", content_type: "application/pdf", byte_size: byte_size(pdf_binary)},
        pdf_binary
      )

      {:ok, job} = Documents.queue_ingestion(upload)

      # Wait for completion
      assert_eventually(fn ->
        job = Repo.get!(IngestionJob, job.id)
        job.state == "completed"
      end, timeout: 120_000)

      # Verify results
      upload = Repo.get!(DocumentUpload, upload.id)
      assert upload.status == "parsed"

      parses = Repo.preload(upload, :parses).parses
      assert length(parses) == 1
      assert parses |> hd() |> Map.get(:parsed_text) |> String.length() > 0
    end

    @tag :slow
    test "handles timeout gracefully", ctx do
      # Use a very short timeout to trigger timeout
      original_timeout = Application.get_env(:medlum, :ingestion)[:conversion_timeout_ms]
      Application.put_env(:medlum, :ingestion, conversion_timeout_ms: 1_000)  # 1 second

      on_exit(fn ->
        Application.put_env(:medlum, :ingestion, conversion_timeout_ms: original_timeout)
      end)

      pdf_path = Path.join(__DIR__, "../fixtures/medium_test.pdf")
      pdf_binary = File.read!(pdf_path)

      {:ok, upload} = Documents.create_upload(ctx.scope, ctx.patient, ctx.record_set,
        %{filename: "test.pdf", content_type: "application/pdf", byte_size: byte_size(pdf_binary)},
        pdf_binary
      )

      {:ok, job} = Documents.queue_ingestion(upload)

      # Wait for failure after retries
      assert_eventually(fn ->
        job = Repo.get!(IngestionJob, job.id)
        job.state == "failed"
      end, timeout: 30_000)

      job = Repo.get!(IngestionJob, job.id)
      assert job.last_error =~ "timeout"
      assert length(job.error_history) > 0
    end

    @tag :slow
    test "retry recovers from transient failure", ctx do
      # This would require mocking Docling to fail once then succeed
      # Alternatively, test with a flaky network simulation
    end
  end

  describe "cleanup mechanisms" do
    test "stale job cleanup marks stuck jobs as failed", ctx do
      # Create a job that looks stuck
      {:ok, upload} = create_test_upload(ctx)
      {:ok, job} = Documents.queue_ingestion(upload)

      # Manually set to processing with old timestamp
      stale_time = DateTime.add(DateTime.utc_now(), -120, :minute)
      job
      |> Changeset.change(%{state: "processing", updated_at: stale_time})
      |> Repo.update!()

      # Run cleanup
      IngestionCleanupWorker.perform(%Oban.Job{})

      # Verify job marked as failed
      job = Repo.get!(IngestionJob, job.id)
      assert job.state == "failed"
      assert job.last_error =~ "stale"
    end
  end

  # Helper to wait for condition with timeout
  defp assert_eventually(func, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :interval, 500)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_assert_eventually(func, deadline, interval)
  end

  defp do_assert_eventually(func, deadline, interval) do
    if func.() do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(interval)
        do_assert_eventually(func, deadline, interval)
      else
        flunk("Condition not met within timeout")
      end
    end
  end
end
```

### 4. Property-Based Tests

```elixir
# test/medlum/documents/ingestion_properties_test.exs
defmodule Medlum.Documents.IngestionPropertiesTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Medlum.Documents.IngestionConfig

  property "retry backoff is always positive and bounded" do
    check all attempt <- integer(1..100) do
      backoff = IngestionConfig.retry_backoff_ms(attempt)
      assert backoff > 0
      assert backoff <= 300_000  # Max 5 minutes
    end
  end
end
```

### 5. Load/Stress Tests

```elixir
# test/medlum/documents/ingestion_load_test.exs
defmodule Medlum.Documents.IngestionLoadTest do
  use Medlum.DataCase, async: false

  @moduletag :load
  @moduletag timeout: 600_000  # 10 min

  describe "concurrent job handling" do
    @tag :slow
    test "handles multiple concurrent uploads", ctx do
      # Queue 10 small PDFs concurrently
      pdf_binary = File.read!(Path.join(__DIR__, "../fixtures/tiny_test.pdf"))

      jobs = for i <- 1..10 do
        {:ok, upload} = Documents.create_upload(
          ctx.scope, ctx.patient, ctx.record_set,
          %{filename: "test_#{i}.pdf", content_type: "application/pdf", byte_size: byte_size(pdf_binary)},
          pdf_binary
        )
        {:ok, job} = Documents.queue_ingestion(upload)
        job
      end

      # Wait for all to complete
      Enum.each(jobs, fn job ->
        assert_eventually(fn ->
          j = Repo.get!(IngestionJob, job.id)
          j.state in ["completed", "failed"]
        end, timeout: 300_000)
      end)

      # Check success rate
      completed = Enum.count(jobs, fn job ->
        Repo.get!(IngestionJob, job.id).state == "completed"
      end)

      assert completed >= 8  # Allow some failures
    end
  end
end
```

---

## Implementation Plan

### Phase 1: Foundation (Week 1)

1. **Add new fields to IngestionJob schema**
   - Migration for `attempt_number`, `max_attempts`, `deadline_at`, `error_history`, etc.

2. **Create IngestionConfig module**
   - Centralize all timeout/limit configuration

3. **Update Documents context**
   - Add `cancel_ingestion_job/1`
   - Add `mark_job_*` state transition functions

### Phase 2: Worker Improvements (Week 1-2)

1. **Rewrite DoclingIngestionWorker**
   - Circuit breaker logic
   - Error recording
   - Cancellation support

2. **Add IngestionCleanupWorker**
   - Schedule via Oban Cron
   - Implement stale job cleanup
   - Implement archival

### Phase 3: Self-Healing (Week 2)

1. **Create IngestionHealthChecker GenServer**
   - Periodic health checks
   - State reconciliation
   - Docling service monitoring

2. **Add to supervision tree**

### Phase 4: Testing (Week 2-3)

1. **Create test fixtures**
   - Small, medium, large test PDFs

2. **Implement unit tests**

3. **Implement integration tests**
   - Full pipeline tests
   - Cleanup tests

4. **Add CI integration**
   - Start Docling service in CI
   - Run integration tests

### Phase 5: Observability (Week 3)

1. **Add Telemetry events**
   - Job started/completed/failed
   - Processing times
   - Queue depths

2. **Dashboard metrics**
   - Jobs processed/hour
   - Average processing time
   - Failure rate

---

## Configuration Reference

```elixir
# config/config.exs
config :medlum, :ingestion,
  conversion_timeout_ms: 1_200_000,     # 20 minutes
  max_retries: 3,
  stale_job_threshold_minutes: 60,
  archive_after_days: 7,
  max_file_size_bytes: 50_000_000,      # 50 MB
  max_pages: 1000,
  cleanup_schedule: "*/15 * * * *",      # Every 15 minutes
  health_check_interval_ms: 60_000       # 1 minute
```

---

## Monitoring & Alerts

### Key Metrics to Track

1. **Queue Health**
   - Queue depth
   - Average wait time
   - Jobs per hour

2. **Processing Health**
   - Success rate
   - Average processing time
   - Timeout rate

3. **System Health**
   - Docling service status
   - Worker utilization
   - Memory usage

### Alert Conditions

- Queue depth > 50 for > 10 minutes
- Failure rate > 20% in last hour
- Docling service unreachable > 5 minutes
- Stale jobs > 10

---

## Migration Path

1. Deploy new schema migrations
2. Deploy new worker code (backwards compatible)
3. Add cleanup worker to Oban cron
4. Monitor for issues
5. Remove old code paths after validation
