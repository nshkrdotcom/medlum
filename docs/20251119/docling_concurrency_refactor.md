# Docling Concurrency Refactor

## Context

Our Docling ingestion service currently runs every PDF conversion under a single global lock (`_converter_lock`). This guarantees only one document converts at a time. On production-sized PDFs (8–10 MB), a single conversion can take up to 5 minutes. During that window all other uploads sit at the 50 % “Docling” stage and eventually hit the timeout if the backlog grows. We also saw the service get OOM-killed while trying to ingest a large PDF, which causes cascading failures.

## Goals

1. Allow multiple conversions to execute concurrently so one long PDF doesn’t block everything.
2. Maintain memory limits so we don’t spawn unbounded OCR workers.
3. Provide progress telemetry per conversion (page-level or chunk-level) so we can surface progress in the Phoenix UI.
4. Preserve the existing API (`POST /convert`) so Phoenix continues to upload PDFs without client changes.

## Proposed Refactor

### 1. Worker Pool
- Replace the single `_converter_lock` with an asyncio-semaphore-backed worker pool (configurable size, default 2–4 workers).
- Each worker owns its own `DocumentConverter` instance; we instantiate N converters at startup.
- Incoming `/convert` requests enqueue PDF conversion tasks; each task acquires the semaphore and runs on its own worker.

### 2. Job Tracking
- Assign a UUID to each conversion and return it immediately (HTTP 202) or keep current synchronous POST but include conversion metadata (job_id, queue_position, estimated wait).
- Persist job state (queued, running, completed, failed) in Redis or an in-memory structure with eviction. Phoenix can poll `/status/:job_id` or subscribe to SSE/WebSocket events for progress updates.

### 3. Progress Telemetry
- Instrument `generate_multimodal_pages` inside Docling to emit “page processed” events. Include total pages to compute percent complete.
- For OCR-heavy PDFs, emit sub-page milestones (e.g., table detection, OCR chunk) so the UI can move beyond a static 50 % bar.

### 4. Resource Controls
- Set per-worker memory limits by running each converter in its own subprocess, monitoring RSS, and killing/respawning workers if they exceed thresholds.
- Stagger GPU/CPU usage by pinning OCR models to the worker; optional config to toggle GPU if available.

### 5. Client/API Changes
- Short term: keep synchronous POST but allow `wait_for` to return early if the queue exceeds a threshold, advising the client to poll `/status/:job_id`.
- Long term: switch Phoenix to async ingestion—upload PDF, receive job_id, subscribe to job progress channel, and render per-document countdown/progress from the streamed events.

## Risks
- Increased memory footprint: multiple converters mean multiple OCR models in RAM (each ~500 MB). Need to right-size the worker count for the VM.
- Complexity of progress streaming: requires new channels or SSE, plus Phoenix changes to consume them.
- Backward compatibility: we need to ensure old clients (if any) continue to work even if they don’t poll `/status`.

## Next Steps
1. Prototype a 2-worker pool with a FIFO queue and per-job telemetry stored in ETS/Redis.
2. Update Phoenix ingestion to handle async responses (receive job_id, poll `/status`, update LiveView with streaming progress).
3. Add monitoring dashboards (Prometheus/Grafana) to watch Docling queue length, worker utilization, and conversion latencies.
4. Load test with parallel uploads to validate memory caps and tune worker count on production hardware.
