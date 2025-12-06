# Robust Gemini LLM Cancellation — Investigation Brief (Subagent Prompt)

Date: 2025-12-05  
Scope: Create a hard-cancel design for report sections that truly stops Gemini HTTP calls (not just marking DB state). This document is the prompt for a subagent to perform a full investigation and recommend the implementation plan.

---

## Background (current flow to anchor the investigation)

- Section execution runs inside Oban, not the LiveView. `Lumainus.Reports.SectionRunWorker.perform/1` triggers `SectionRunner.run_section/5` or `.run_section_streaming/5` depending on args (`lib/lumainus/reports/section_run_worker.ex:15-44`).
- LLM calls are made synchronously inside `Lumainus.AI.SectionRunner`:
  - Non-streaming path calls `AI.client().generate_object/4`, which uses `Gemini.generate/2` under the hood (`lib/lumainus/ai/section_runner.ex:18-129`, `lib/lumainus/llm.ex:18-119`).
  - Streaming path uses `Gemini.Streaming.UnifiedManager.start_stream/3` and spawns a translator process that receives UnifiedManager events and forwards them to the worker process (`lib/lumainus/ai/section_runner.ex:131-291`, `lib/lumainus/llm.ex:141-291`).
- The LiveView only tracks `running_sections` as a UI MapSet derived from section status; it does **not** hold PIDs or Oban job IDs (`lib/lumainus_web/live/reports_live.ex:733-760`). Navigating away or closing the LiveView does not stop the running section.
- Timeouts: the streaming receive loop in `SectionRunner` has a 10-minute `receive` timeout; this does not actively abort the underlying HTTP request.
- Data models: `report_section_runs.status` and `llm_invocations.status` currently use strings like `"pending"`, `"running"`, `"completed"`, `"error"`; no explicit `"cancelled"` state yet (`lib/lumainus/reports/report_section_run.ex:6-42`, `lib/lumainus/ai/llm_invocation.ex:7-67`).

## Problem to solve

- Soft cancel today would only mark DB status as cancelled; the Gemini HTTP call (Req-based) keeps running until completion/timeout.
- Hard cancel must actually stop the LLM work: terminate the Elixir process making the HTTP call so the TCP connection is closed and no further callbacks run.
- gemini_ex likely lacks a true “abort request” API; Req itself has no “abort” once in-flight. Stopping the caller process is the standard pattern.

## What “hard cancel” should mean (for this codebase)

1. User clicks Cancel on a running section → server receives event.
2. Server looks up the live process(es) performing that section’s Gemini call (and any translator/subprocess).
3. Server terminates them (`Process.exit(pid, :kill)` or `Task.Supervisor.terminate_child/2` / `Task.shutdown(task, :brutal_kill)`), ensuring the socket is closed.
4. Persist `report_section_runs.status = "cancelled"` and `llm_invocations.status = "cancelled"` with `error` describing “cancelled by user”.
5. Prevent further writes from the killed process (idempotent persistence, guard rails in `SectionRunner` to check `cancelled?` flags early).
6. Oban jobs for the cancelled section should be marked cancelled or treated as finished without retries.

## Known constraints and risks

- gemini_ex streaming: `UnifiedManager.stop_stream/1` only stops client-side tracking; it does **not** abort the HTTP request. Killing the process is the effective lever.
- Req (the HTTP client gemini_ex uses) has no abort handle; killing the caller is required to drop the connection.
- Oban jobs are not linked to the LiveView process. Without tracking, the UI cannot target the right process to kill.
- Streaming uses two processes: the SectionRunner process (Oban worker) and the spawned translator process that subscribes to UnifiedManager events. Both must be terminated for a clean stop.

## Investigation tasks for the subagent

1. **Map execution ownership**
   - Identify exactly which processes own Gemini calls for both streaming and non-streaming flows (SectionRunner vs translator vs Oban worker).
   - Confirm whether SectionRunner uses Task, Task.Supervisor, or plain function calls (today looks synchronous).
2. **Find all Gemini entry points**
   - Trace every call into `Lumainus.LLM` and `Gemini.Streaming.UnifiedManager` (streaming start/stop, subscriptions).
   - Note any long-lived processes or monitors.
3. **Assess cancel hooks**
   - Check if gemini_ex exposes any cancel/stop besides `stop_stream/1`.
   - Confirm whether Req has any hidden cancellation handle (likely no).
4. **State tracking options**
   - Where to store per-section run “in-flight handle”: ETS table, dedicated GenServer, or Oban job metadata.
   - Data to store per section: `section_run_id`, Oban `job_id`, `llm_pid` (caller), `translator_pid` (streaming), optional `stream_id`.
5. **Kill strategy**
   - Evaluate `Process.exit(pid, :kill)` vs `Task.Supervisor.terminate_child/2` vs Oban `cancel_job/1`.
   - For streaming, ensure translator processes and any UnifiedManager subscriptions are torn down.
   - Consider adding a cooperative `cancelled?` check inside SectionRunner to avoid post-cancel writes.
6. **Persistence model**
   - Decide on adding `"cancelled"` status to `report_section_runs` and `llm_invocations`.
   - Define error payload shape for cancellations to avoid retry and to inform UI.
7. **UI → backend wiring**
   - Identify the best place to expose a Cancel button in Reports LiveView.
   - Determine event handler: should it call Oban to cancel jobs, kill tracked PIDs, mark DB, and broadcast updates.
8. **Testing approach**
   - Plan Bypass/Req mocks to assert that killing the process stops further callbacks.
   - Tests for DB status transitions and absence of post-cancel writes.
   - Streaming-specific test to ensure translator stops broadcasting chunks after cancel.

## Recommended design hypotheses to validate

- **Tracking**: Add a small `SectionCancellation` module (ETS or GenServer) keyed by `section_run_id` storing `%{job_id, llm_pid, translator_pid, stream_id}`. Populate it when SectionRunner starts a call; clear it on completion/error.
- **Invocation isolation**: Wrap the Gemini call in a Task supervised by a `Task.Supervisor` owned by the Oban worker or a shared supervisor. That gives a target for `terminate_child/2`.
- **Cancel path**: LiveView “Cancel” event → server handler:
  1. Mark the section as `cancelled` in DB (and optionally Oban job as cancelled).
  2. Lookup PIDs/stream_id in `SectionCancellation`; `Process.exit(pid, :kill)` on worker and translator; optionally call `UnifiedManager.stop_stream/1` to drop client bookkeeping.
  3. Remove tracker entry; broadcast update so UI reflects cancelled state.
- **Fallback timeout**: Keep the 10-minute timeout but add a shorter watchdog (e.g., 5–6 minutes) to auto-cancel zombies.
- **Idempotency**: SectionRunner should short-circuit if `cancelled?` is detected mid-flight to prevent writing “completed” after a cancel.

## Open questions for the agent to answer

- Does gemini_ex expose any lower-level Req handles that could be aborted without killing the process?
- What side effects does killing the translator process leave in UnifiedManager (subscriptions, monitors)? Do we need cleanup?
- How does Oban treat `:cancelled` vs `:discard` for jobs already running? Which should we use?
- Are there other long-running steps (Docling, cache fetch) that also need cancellation to avoid partial state?
- What telemetry/log hooks should we add to confirm cancels are happening and to trace user-initiated cancels?

## Deliverables expected from the subagent

- A concise report enumerating current call paths and process ownership with file:line references.
- A recommended hard-cancel design (MVP and ideal) covering tracking, kill path, persistence, and UI/API hooks.
- Risk list and mitigation strategies for Req/gemini_ex limitations.
- Test plan and suggested fixtures/mocks to prove cancellation works.

## Ready-to-send prompt for the subagent

Use the following prompt verbatim when engaging the subagent:

```
You are investigating how to implement a truly hard “Cancel” for report generation in the Lumainus codebase.

Context:
- Stack: Elixir/Phoenix 1.8, LiveView, Oban for background jobs, gemini_ex client for LLM, Req HTTP under the hood.
- Current pain: “Soft cancel” only marks DB as cancelled; the HTTP request keeps running until Gemini responds or times out. We need to actually stop the LLM call and close the connection.
- LiveView misconceptions: Killing the LiveView/HTML does nothing; LLM runs server-side in background processes.

Goals:
1) Map current execution flow for report/section generation: where tasks/processes are spawned, how Gemini calls are invoked, and how statuses are persisted.
2) Identify all places where Gemini is called (modules/functions) and how requests are issued (Req/Finch/Task/Task.Supervisor/Oban).
3) Determine what gemini_ex supports (especially cancellation/stream stop) and its limitations with Req; confirm whether any API aborts the HTTP request or only stops client-side handling.
4) Propose a concrete design for hard cancel that actually stops the running HTTP call. Include:
   - How to track the PID/task/ref per section/report run (ETS? GenServer? LiveView assigns? Oban metadata?).
   - How to kill it (Process.exit/Task.shutdown/terminate_child) without leaving dangling state.
   - How to mark DB statuses (“cancelled”) and ensure idempotent cleanup.
   - How to handle streaming vs non-streaming calls; what happens to TCP/socket.
   - Timeouts/fallbacks to avoid zombies.
5) Identify risks/trade-offs: Req lacks abort; does gemini_ex stop_stream only end client processing? Do we need Finch with connection handles? Any supervision concerns?
6) Testing/verification plan: how to assert cancellation works (mocks/Bypass, asserting process exit, status update, no further DB writes).

Deliverables:
- Short report with code paths (file:line), current behavior, gemini_ex/Req limits, and a recommended approach (MVP and ideal) for hard cancel.
- Call out any required schema/status changes and UI hooks (e.g., cancel button event -> server call -> process kill).
- Include open questions and decision points.

Constraints:
- Do not change code; only investigate and report.
- Keep references precise (module/function, file:line).
```

## Non-goals for the subagent

- No code changes or migrations in this pass.
- No UI redesign; only propose where/how to wire cancel.
- No Docling ingestion cancel design (unless it directly blocks section cancellation).

---

Use this doc as the single source of truth for the subagent engagement. Update it after the investigation with findings and chosen implementation path.
