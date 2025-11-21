# Continuation Prompt — Docling Telemetry Integration (Lumainus)

## Context (state as of 2025-11-20)
- Docling service (FastAPI) now has:
  - Async queue with worker(s), job event bus, enriched `/jobs/:id/status`, and SSE stream `/jobs/:id/stream`.
  - Telemetry events: `queued`, `started`, `page_processed`, `completed/failed/timeout`, with `pages_done/total`, `progress`, `worker_id`, `device`, `queue_depth`, `elapsed_ms`.
  - Uvicorn access logs are noisy (one line per status poll).
- Phoenix side:
  - Config: `config/config.exs` sets `:docling` `queue_mode: :http_queue`; test env stays inline.
  - Ingestion pipeline dedupes progress updates; LiveView handles `DateTime` timeouts without crashing.
  - Currently still polling `/jobs/:id/status` every ~1s (no SSE consumer yet); progress DB writes are suppressed unless values change, but logs remain noisy.
- Docling fork installed editable (`docling` version tagged `2.63.0+lumainus`) and docling_service run script installs it by default.

## Required reading before coding
- `docling_service/app/main.py` (SSE + status payloads)
- `lib/lumainus/docling/queue.ex` (polling client)
- `lib/lumainus/documents/ingestion_processor.ex` (progress handling)
- `lib/lumainus_web/live/reports_live.ex` (ingestion UI updates + timeout handling)
- Configs: `config/config.exs` (queue mode), `config/test.exs` (inline mode for tests)
- Addenda: `AGENTS.md` + Telemetry Addendum, `docs/20251120/telemetry.md`

## Target task
1) Switch Phoenix to consume Docling SSE (`/jobs/:id/stream`) and broadcast via PubSub to LiveView (stop tight polling).
2) Keep a slow fallback poll (e.g., 5s) if SSE drops.
3) Disable/silence docling_service access logs (uvicorn) and reduce noise in Phoenix logs.

## Implementation sketch
- Docling client:
  - Add SSE subscribe helper (e.g., `Docling.subscribe(job_id, handler)` using `Finch` or `Mint.HTTP` with `text/event-stream`).
  - Integrate in ingestion worker: start SSE stream on enqueue, forward events to `Documents.notify_job_progress`; on disconnect, fall back to the slower status poll (5s).
  - Ensure cleanup of SSE processes on job completion/failure.
- Phoenix LiveView:
  - Existing `handle_info {:job_progress, ...}` already updates documents; no template change needed unless adding page counts/status text.
  - Avoid reloading workspace on every Docling update; rely on PubSub updates only.
- Config:
  - Add `poll_interval_ms: 5000` (status fallback) in `config/config.exs`.
  - docs: note that test env stays inline.
- Docling service logs:
  - Disable uvicorn access logs: set env `UVICORN_ACCESS_LOG=false` (and optionally `UVICORN_LOG_LEVEL=warning`) in `docling_service/run.sh` or systemd unit.
  - Optionally add structured event logs and leave access logs off.

## Notes
- Keep tenant/auth isolation: Docling network calls stay server-side; do not expose Docling directly to browser.
- Ensure SSE consumer respects timeouts and won’t hang the worker; supervise with a Task and timeout.
- Leave `/convert` compatibility intact; `/jobs` queue is the preferred path.
