# Docling Dual-Backend Rollout Plan (Local CPU vs Remote GPU/Vast.ai)

**Goal:** Let each user pick between the default slow/free local Docling CPU backend and a “Fast (GPU, $$)” backend (initially Vast.ai) directly from `/reports`, with a persistent per-user setting and basic cost awareness. End-to-end should work for both backends.

**Decisions**
- Keep current local Docling CPU as the default.
- Expose a per-user “Docling speed” setting stored on their account (persist across sessions). Values: `local` (default) and `fast` (GPU/Vast).
- Use the existing Docling HTTP service interface; no custom Docling Docker build. For GPU we keep using the published Docling image (e.g., pytorch base / upstream image) rather than building a bespoke image.
- Remote GPU backend = Vast.ai-hosted Docling service reachable via HTTP. Instance management can reuse `docling_service/manage_vast.py` scripts; no SSH tunnels required.
- Minimal cost tracking: record backend choice + elapsed time + page count per ingestion job; surface a simple daily/weekly summary for “fast” jobs.

---

## Implementation Steps (sequence)

1) **Backend Abstraction Finalization**
   - Land the `Lumainus.Docling.Backend` behaviour and `Lumainus.Docling.HTTP` client (from the 20251123 design).
   - Implement and register two backends: `Local` (CPU) and `Remote` (GPU/Vast). `Remote` reads `:docling, :remote_url`.
   - Wire `Lumainus.Docling` facade to select backend by name and keep a default (`:local`).

2) **Configuration**
   - Add config keys:
     ```elixir
     config :lumainus, :docling,
       backend: :local,
       timeout_ms: 1_200_000,
       local_url: "http://127.0.0.1:8042",
       remote_url: System.get_env("DOCLING_REMOTE_URL"),
       poll_interval_ms: 5_000
     ```
   - Keep prod runtime requirement for `DOCLING_REMOTE_URL` when fast mode is enabled.

3) **Per-User Setting**
   - DB: add column on users (or user settings table) `docling_backend` (string), default `"local"`. Constraint allowed values: `local`, `fast`.
   - Context: expose `get_docling_backend(user)` that falls back to config default.
   - LiveView `/reports`: add UI knob (toggle/select) labeled e.g., “Processing speed: Standard (free) / Fast (GPU, $$)”. On change, persist to the user setting and update assigns.
   - Ensure the selected backend is injected into ingestion job opts (see step 4).

4) **Ingestion Pipeline Wiring**
   - When queuing ingestion (`Documents.queue_ingestion/…`), pass `backend` from user setting into `Lumainus.Docling.enqueue/2` or `convert/2`.
   - Store `backend` on `ingestion_jobs` (add column) and propagate to `DocumentUpload.metadata` for later display.
   - In `IngestionProcessor.await`, respect the job’s backend module when calling `await/2`.

5) **Vast.ai Remote Backend**
   - Use `Remote` backend pointing at the Vast.ai Docling HTTP endpoint. (No tunnels; straight HTTP with optional token if Nginx sidecar is used.)
   - Operational steps to bring up Vast (see “Operator Checklist” below) produce `DOCLING_REMOTE_URL`.
   - Optional: keep `VastAI` backend placeholder only if you want auto-provision; otherwise start with static `Remote` pointing to a manually provisioned Vast instance.

6) **Cost & Usage Tracking (basic)**
   - Capture per job:
     - `backend` (local|fast)
     - `pages_total` (if available from Docling status)
     - `duration_ms`
   - Add a daily counter (materialized via simple query) for “fast” jobs. Surface on admin dashboard and optionally a small banner in `/reports` when in fast mode (“Fast mode uses GPU hours; check admin for usage.”).
   - Log format: `DOCLOG backend=<fast|local> pages=<n> duration_ms=<n> user_id=<id> job_id=<id>`.

7) **UI/UX**
   - In `/reports`, show the chosen mode per user and per upload card (badge: “Standard” vs “Fast (GPU)”).
   - If remote health check fails, disable fast selection with a tooltip “GPU service unavailable”.
   - Add a small info note explaining that “Fast” incurs GPU cost.

8) **Health & Fallback**
   - `Lumainus.Docling.health/0` should check the currently selected backend. If fast backend is unhealthy, prompt the user to switch back to Standard, and automatically fall back to local for new jobs.

9) **Testing Checklist**
   - Unit: user setting persists; backend selection returns expected module.
   - Integration (local): convert + enqueue/await round-trip.
   - Integration (remote): against running Vast endpoint; enqueue/await succeeds; health passes; UI shows “Fast”.
   - Failure: remote down → health fails → fast toggle disabled; jobs queued with fallback to local.
   - Cost fields recorded: verify job metadata and logs.

10) **Cutover**
   - Deploy code + migrations.
   - Provision Vast.ai endpoint and set `DOCLING_REMOTE_URL`.
   - Smoke test both modes with small PDFs; then with a large PDF to confirm speed delta.
   - Announce user-facing switch in `/reports`.

---

## Operator Checklist for Vast.ai (manual, no tunnels)

1) Build/obtain Docling image:
   - Use upstream/pytorch-based Docling image (no custom build).
2) Provision Vast instance (GPU: RTX 3090) using `docling_service/manage_vast.py provision`.
   - Export `VAST_API_KEY` first.
   - Capture the output endpoint `http://<ip>:8042` (or via Nginx token if enabled).
3) Set app env:
   - `DOCLING_REMOTE_URL=http://<ip>:8042`
4) Verify health:
   - `curl $DOCLING_REMOTE_URL/health` returns 200.
5) Enable fast mode in app:
   - Deploy config and restart.

---

## What You Need To Do (summary)

1. Add migrations: `users.docling_backend` default “local”; `ingestion_jobs.backend` (nullable default “local”).
2. Implement backend behaviour + HTTP client + Local/Remote backends; wire `Lumainus.Docling` facade to select backend and respect job.backend in await.
3. Add user-setting toggle in `/reports`, persist choice, and pass it into ingestion jobs.
4. Wire basic cost tracking fields (backend, pages, duration) and a simple admin summary.
5. Provision Vast instance and set `DOCLING_REMOTE_URL`; test both modes; add health/fallback logic.

Once these are complete, `/reports` will let users pick “Fast (GPU, $$)” or “Standard (Free)” with persistent settings and working end-to-end conversions on either backend.
