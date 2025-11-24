# Docling Progress Latency Debug Prompt

Use this prompt for a follow-on agent to investigate UI vs Docling log latency.

## Goal
Make the Phoenix LiveView progress display update in near lockstep with Docling CLI logs (page_processed events). Capture timestamps from both sides and identify where delay is introduced (Docling SSE -> Phoenix -> LiveView).

## Quick Enable: Progress Debug Logs
- Set `:debug_progress_log` in `config/dev.exs` or at runtime to `true`:
  ```elixir
  config :lumainus, :docling, debug_progress_log: true
  ```
  or in IEx:
  ```elixir
  Application.put_env(:lumainus, :docling, Keyword.put(Application.get_env(:lumainus, :docling, []), :debug_progress_log, true))
  ```
- Run ingestion. Phoenix console will emit lines like:
  ```
  [docling-progress-debug] job=abc type=page_processed page=12/764 overall=18 stage_seq=5 worker=1 device=cpu queue_depth=0 event_ts=1.732003687859813e9 now_ms=1732003688123
  ```
  Compare `event_ts` (Docling epoch seconds) with `now_ms` to measure gap.

## Steps for the Agent
1) Tail Phoenix logs during ingestion and capture `docling-progress-debug` lines.
2) Tail Docling service logs (CLI) side-by-side; note the time each page_processed appears.
3) Measure delta:
   - Docling CLI timestamp vs `event_ts` (Docling payload) vs `now_ms` (Phoenix receipt).
   - If `event_ts` ~ CLI time but `now_ms` lags, network/stream buffering is suspect.
   - If `event_ts` already lags CLI, issue is inside Docling service event emission.
4) Check SSE stream framing:
   - Confirm events are flushed with `\n\n` and not buffered by server/proxy.
   - If buffering suspected, consider forcing line buffering or adding `yield`/`await asyncio.sleep(0)` in the SSE generator.
5) Confirm Phoenix side:
   - `Lumainus.Docling.SSEConsumer` and `Docling.Queue.receive_sse_events/5` process every `:data` chunk immediately.
   - `ProgressTracker.should_emit?/4` now emits on every page movement (no debounce on page count; only 50ms debounce when progress is flat).
6) If still laggy, instrument SSE Consumer to timestamp each chunk arrival and compare with `docling-progress-debug`.

## Deliverables
- Identify where the delay occurs (Docling emit, network/SSE buffering, Phoenix receive, LiveView render).
- Provide a minimal fix (SSE flush or buffer tweak) and demonstrate improved timestamps with log samples.

## Artifacts to collect
- Phoenix `docling-progress-debug` log excerpt (5–10 consecutive page updates).
- Docling CLI log excerpt for the same pages.
- Calculated latency stats (min/avg/max).
