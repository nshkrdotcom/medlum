# Docling Ingestion Reliability & Architecture Design

_Date: 2025-11-20_

## Context

Medlum ingests clinical PDFs via a Phoenix LiveView app backed by a Python “Docling” service. The current development stack is a single Linode VM running:

- Phoenix (LiveView, Oban) serving `/reports`
- Docling FastAPI (Docling 2.62 + RapidOCR) bound to `127.0.0.1:8042`
- Postgres

Uploads are handled by LiveView, stored in `document_uploads`, and an Oban worker immediately calls `Docling.convert/2`. Because Docling is single-threaded (`_converter_lock`), large PDFs (8–10 MB) or OCR-heavy files take minutes, during which the LiveView remains at 50 % with no progress telemetry. When Docling times out or is OOM-killed, the LiveView often collapses the document card, giving the user no indication of failure.

Recent instrumentation added:

- Phoenix now logs “Docling convert start/finish” with upload/job IDs and durations.
- Docling adds request logging + a configurable timeout (now 300 s).
- LiveView displays a “Will timeout in mm:ss” countdown for each document in Docling stage.
- Docling failures are surfaced in Phoenix logs and document metadata (`ingestion_message`).

Remaining problems:

- Docling runs only one conversion at a time; queueing multiple PDFs blocks ingestion.
- When Docling crashes, Phoenix retries, but the user still sees “Awaiting ingestion” without a clear error state.
- There’s no persistent job table to inspect outstanding conversions, no SSE/SSE for real-time updates, and progress is limited to “stage + percent” heuristics.
- The docling service shares the same VM and fights for RAM; large OCR models can trigger OOM.

## Desired State

1. **Observability:** Every upload should have a visible status (queued/running/failed) with timestamps and remaining timeout. Operators should be able to see docling health at a glance and drill into individual job logs.
2. **Asynchronous ingestion:** Phoenix should treat Docling as an async job—submit, get a job_id, stream updates via PubSub. LiveView should never remove the document entry; it should show the last known state and allow manual retry.
3. **Concurrency (future-facing):** Docling should support multiple workers or at least a queue depth > 1, with resource limits. Even if we maintain single-worker in dev, architecture should assume a queue + worker pool so we can lift and shift to ECS later.
4. **Error handling:** Docling timeouts or failures should be reflected in the document card (“Docling timed out; retry?”). Retrying should re-use the stored PDF (no need to re-upload).
5. **Cheap dev-friendly:** Since we’re cost-sensitive, design must work on a single VM with swap, but be “cloud ready” for ECS/EKS.

## Proposed Architecture

### 1. Ingestion Flow (Phoenix)
- When a PDF is uploaded, `document_upload` is inserted with `status=pending` and the card appears immediately.
- Oban enqueue: insert an `ingestion_jobs` row with fields: `id`, `upload_id`, `state`, `progress`, `timeout_at`, `last_error`, `started_at`, `finished_at`.
- Oban worker sends the PDF to Docling via HTTP but wraps the call in a new module `Medlum.Docling.Queue` that maintains job state.
- LiveView subscribes to `job_progress` via PubSub and updates document cards with stage/progress/countdown. On reconnect/resubscribe, it fetches the latest job state from the DB.

### 2. Docling Service Enhancements
- Replace `_converter_lock` with a worker pool (configurable size `DOC_CONVERTER_WORKERS`). Each worker runs on a background thread/process with its own `DocumentConverter`.
- Add a `/jobs` endpoint to enqueue conversions, returning `job_id`. `/jobs/:id/status` returns current state/events. A background task consumes the queue and runs Docling conversions.
- Provide SSE or WebSocket to stream “page processed” events per job (optional at first, but architected).
- Add swap on the VM, or run Docling inside a systemd cgroup with explicit `MemoryMax` to prevent OOM kills.

### 3. Error Surfacing
- Update LiveView to show explicit errors on document cards (e.g., “Docling timed out after 300s. Retry”). Provide a button to requeue the job via Oban without re-uploading.
- Display docling health at top of admin dashboard (already added). Consider showing queue length / job status summary.

### 4. Scripts/Utilities
- `scripts/test_docling.sh` (done) for quick manual curl.
- `mix docling.queue` to inspect queued/running jobs from CLI.
- `mix docling.retry <job_id>` to requeue a failed job.

### 5. Migration Path to ECS
- Containerize Docling + worker pool, set task count to desired concurrency.
- Have Phoenix talk to Docling through an internal ALB with auth.
- Replace in-VM job queue with an SQS or Redis queue.

## Implementation Tasks

1. **Add ingestion_jobs table** (id, upload_id, state, progress, timeout_at, last_error, inserted_at, updated_at). Migrate existing Oban pipeline to populate it.
2. **Refactor Oban worker** to update `ingestion_jobs` rows and always re-use stored PDFs. Provide a manual retry function.
3. **Docling queue module** (`Medlum.Docling.Queue`) that tracks job state and interacts with the Python service.
4. **Python service queue**: implement a simple asyncio queue + worker pool, returning job_id + status endpoints. For short-term dev, keep `/convert` blocking but instrument queue/worker states.
5. **LiveView UI**: ensure document cards stay mounted even on failure, display job state + countdown, and expose “Retry ingestion” action.
6. **Logging/Monitoring**: forward docling logs to journald with structured JSON; add `scripts/logs_docling.sh` tailer.

## Instructions for Agents

1. **Schema & Data Layer**
   - Add a migration for `ingestion_jobs` (fields as described). Update Ecto schemas and context functions to insert/update jobs when `Documents.queue_ingestion/3` runs.
   - Ensure job records track `timeout_at` based on Docling config (300 s) and store last error messages.

2. **Oban Worker Refactor**
   - Modify `DoclingIngestionWorker` (or create a new worker) to:
     - Fetch the `ingestion_job` record.
     - Update `state` (queued → running → completed/failed) and `progress` at each stage.
     - Use `Documents.fetch_upload/1` to get the stored PDF (no re-upload).
     - On timeout or error, record the message and mark `state=failed`.
     - Expose a helper `Documents.retry_ingestion(upload_id)` to requeue a job.

3. **Docling Client Enhancements**
   - Extract Docling HTTP calls into a module that can simulate queueing (for now, still synchronous but returns `job_id`).
   - Log job_id/upload_id in every request, as already started.

4. **Python Service Queue Stub**
   - In `docling_service/app/main.py`, introduce an asyncio queue and configurable worker count.
   - Keep `/convert` for compatibility but internally submit to the queue and wait for result; future tasks can expose `/jobs` once the client is ready.

5. **LiveView Updates**
   - Ensure `ReportsLive` always lists uploads in sorted order even if Docling fails. If `ingestion_jobs.state = failed`, show the error message and a “Retry” button that enqueues a new job.
   - Use the metadata (incl. `ingestion_timeout_at`) to drive the countdown (already done) and show more detailed statuses (queued, running, retrying).
   - Add a visible banner/flash when docling is down (`docling_health` indicates `unreachable`).

6. **Documentation & Scripts**
   - Update README/docs with instructions on using `scripts/test_docling.sh` and the new job monitoring commands.
   - Document how to increase swap on the dev VM to prevent OOM during large conversions.

Deliverables: migration, Ecto schemas, updated worker, Docling queue module, Python queue + logging, LiveView UI tweaks, scripts/doc updates.

## Operational notes (2025-11-20)

- Docling now exposes `/jobs` + `/jobs/{id}/status` and runs an asyncio queue with `DOC_CONVERTER_WORKERS` workers (default `1`). The legacy `/convert` endpoint still blocks but submits through the queue internally.
- Phoenix ships `Medlum.Docling.Queue` to correlate job IDs, broadcast PubSub progress, and attach `timeout_at/last_error` to `ingestion_jobs`.
- CLI helpers: `mix docling.queue [limit]` lists recent jobs, `mix docling.retry <job_id>` requeues a failed job using the stored PDF, and `scripts/logs_docling.sh` tails journald for the Docling unit.
- Swap quick-start for the single-VM dev stack (tweak sizes as needed):
  ```bash
  sudo fallocate -l 4G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  ```
  Consider pinning Docling under a `systemd` unit with `MemoryMax=` to prevent the OCR models from OOM-killing the host.
