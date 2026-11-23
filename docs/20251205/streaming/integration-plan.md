# Streaming Integration & Build Plan

## Review Summary

After reviewing both the backend and frontend designs, here's the consolidated integration plan for implementing real-time LLM streaming on the `/reports` page.

---

## Architecture Validation

### Key Integration Points

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           STREAMING DATA FLOW                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────────────────────┐│
│  │ ReportsLive  │────>│   Reports    │────>│    SectionRunWorker          ││
│  │ (LiveView)   │     │   Context    │     │    (Oban Job)                ││
│  │              │     │              │     │    stream: true              ││
│  └──────┬───────┘     └──────────────┘     └─────────────┬────────────────┘│
│         │                                                 │                 │
│         │                                                 ▼                 │
│         │                                  ┌──────────────────────────────┐│
│         │                                  │    SectionRunner             ││
│         │                                  │    run_section_streaming/5   ││
│         │                                  └─────────────┬────────────────┘│
│         │                                                 │                 │
│         │                                                 ▼                 │
│         │                                  ┌──────────────────────────────┐│
│         │                                  │    Medlum.LLM              ││
│         │                                  │    stream_generate/5         ││
│         │                                  └─────────────┬────────────────┘│
│         │                                                 │                 │
│         │                                                 ▼                 │
│         │                                  ┌──────────────────────────────┐│
│         │                                  │    gemini_ex                 ││
│         │                                  │    UnifiedManager            ││
│         │                                  │    HTTPStreaming             ││
│         │                                  └─────────────┬────────────────┘│
│         │                                                 │                 │
│         │               PubSub                            │                 │
│         │         {:llm_chunk, ...}                       │                 │
│         │◄────────────────────────────────────────────────┘                 │
│         │                                                                   │
│         ▼                                                                   │
│  ┌──────────────┐                                                           │
│  │ handle_info  │                                                           │
│  │ updates      │                                                           │
│  │ streaming_   │                                                           │
│  │ content      │                                                           │
│  └──────────────┘                                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Design Compatibility

| Aspect | Backend Design | Frontend Design | Compatible? |
|--------|---------------|-----------------|-------------|
| PubSub Topic | `"report-run:#{record_set_id}"` | Subscribes via existing pattern | ✅ Yes |
| Message Format | `{:llm_chunk, %{section_run_id, text, usage}}` | Expects same format | ✅ Yes |
| Completion Signal | `{:section_run_updated, ...}` (existing) | Already handles this | ✅ Yes |
| Section ID Mapping | Uses `section_run_id` in messages | Maps to `section_id` via helper | ✅ Yes |

---

## Build Phases

### Phase 1: Backend Infrastructure (No UI changes)

**Goal:** Add streaming capability without breaking existing functionality.

#### Step 1.1: LLM Module Extension
**File:** `lib/medlum/llm.ex`

```elixir
# Add new function (don't modify existing)
def stream_generate(model_spec, prompt_text, schema, subscriber_pid, opts \\ [])
```

**Tasks:**
- [ ] Add `stream_generate/5` function signature
- [ ] Implement `do_stream_generate/6` for Google provider
- [ ] Add `stream_event_translator/3` process
- [ ] Add helper functions: `extract_chunk_text/1`, `extract_chunk_usage/1`
- [ ] Add `build_stream_request_body/2`

#### Step 1.2: SectionRunner Streaming
**File:** `lib/medlum/ai/section_runner.ex`

```elixir
# Add new function (parallel to existing run_section/5)
def run_section_streaming(scope, section_run, patient, documents, opts \\ [])
```

**Tasks:**
- [ ] Add `run_section_streaming/5` entry point
- [ ] Add `invoke_llm_streaming/5`
- [ ] Add `handle_stream_events/7` receive loop
- [ ] Add `broadcast_chunk/3` for PubSub

#### Step 1.3: Worker Support
**File:** `lib/medlum/reports/section_run_worker.ex`

**Tasks:**
- [ ] Add `stream?` flag check in `perform/1`
- [ ] Route to `run_section_streaming/5` when `stream: true`

#### Step 1.4: Reports Context
**File:** `lib/medlum/reports.ex`

**Tasks:**
- [ ] Add `stream` option to `run_sections/6`
- [ ] Pass `stream` flag through to `enqueue_section_runs/3`
- [ ] Include `"stream" => true` in Oban job args

---

### Phase 2: Frontend State Management

**Goal:** Add socket assigns and handle_info without changing template.

#### Step 2.1: Socket Assigns
**File:** `lib/medlum_web/live/reports_live.ex`

**Tasks:**
- [ ] Add `:streaming_content` assign in `load_workspace/1` (around line 762)
- [ ] Initialize as empty map: `%{}`

#### Step 2.2: Handle Info Clauses
**File:** `lib/medlum_web/live/reports_live.ex`

**Tasks:**
- [ ] Add `handle_info({:llm_chunk, ...}, socket)` clause
- [ ] Add `find_section_id_for_run/2` helper function
- [ ] Modify existing `:section_run_updated` handler to clean up streaming state
- [ ] Add content truncation (10k char limit)

---

### Phase 3: Template & Styling

**Goal:** Display streaming content with visual polish.

#### Step 3.1: Template Changes
**File:** `lib/medlum_web/live/reports_live.ex` (lines 4256-4310)

**Tasks:**
- [ ] Add conditional for streaming content display
- [ ] Add `.streaming-header` with spinner + "Generating..." label
- [ ] Add `.streaming-content` container with `<pre><code>`
- [ ] Add `phx-hook="StreamingScroll"` for auto-scroll

#### Step 3.2: CSS Styling
**File:** `lib/medlum_web/live/reports_live.ex` (style block)

**Tasks:**
- [ ] Add `.section-streaming` styles
- [ ] Add `.streaming-header` styles
- [ ] Add `.streaming-content` dark theme styles
- [ ] Add `.streaming-content code` monospace font
- [ ] Add blinking cursor animation
- [ ] Add custom scrollbar styles
- [ ] Add mobile responsive adjustments

#### Step 3.3: JavaScript Hook
**File:** `assets/js/app.js`

**Tasks:**
- [ ] Add `Hooks.StreamingScroll` object
- [ ] Implement `mounted()`, `updated()`, `destroyed()`
- [ ] Add `scrollToBottom()` and `isNearBottom()` helpers
- [ ] Register hook in LiveSocket

---

### Phase 4: Integration & Wiring

**Goal:** Connect backend to frontend and enable streaming.

#### Step 4.1: Enable Streaming in UI
**File:** `lib/medlum_web/live/reports_live.ex`

**Tasks:**
- [ ] Modify `run_sections/2` to pass `stream: true`
- [ ] Or add feature flag check before enabling

#### Step 4.2: Feature Flag (Optional)
**File:** `config/config.exs`

```elixir
config :medlum, :features,
  llm_streaming: true
```

---

## File Change Summary

| File | Changes |
|------|---------|
| `lib/medlum/llm.ex` | Add `stream_generate/5` + helpers (~100 lines) |
| `lib/medlum/ai/section_runner.ex` | Add `run_section_streaming/5` + handlers (~80 lines) |
| `lib/medlum/reports/section_run_worker.ex` | Add stream flag routing (~5 lines) |
| `lib/medlum/reports.ex` | Add stream option passthrough (~10 lines) |
| `lib/medlum_web/live/reports_live.ex` | Add assigns, handle_info, template, CSS (~150 lines) |
| `assets/js/app.js` | Add StreamingScroll hook (~30 lines) |

**Total estimated new code:** ~375 lines

---

## Risk Mitigation

### Risk 1: gemini_ex UnifiedManager API Differences
**Mitigation:** Review actual UnifiedManager interface before implementing. The design assumes specific message formats.

### Risk 2: Performance with Rapid Updates
**Mitigation:**
- Backend: Batch chunks (100 chars / 50ms)
- Frontend: Truncate at 10k chars
- JS: Only scroll if near bottom

### Risk 3: Multiple Simultaneous Streams
**Mitigation:** Use section_id-keyed map for streaming_content. Each section tracked independently.

### Risk 4: Process Lifecycle
**Mitigation:** Stream translator process is linked to worker. If worker crashes, translator dies too. Oban handles retries.

---

## Testing Strategy

### Unit Tests

1. **LLM.stream_generate/5**
   - Receives chunks
   - Handles completion
   - Handles errors
   - Timeout behavior

2. **SectionRunner.run_section_streaming/5**
   - Broadcasts chunks via PubSub
   - Persists final result
   - Handles stream errors

### Integration Tests

1. **Full streaming flow**
   - Subscribe to PubSub
   - Run section with stream: true
   - Receive chunks
   - Verify final state

2. **"Run All" with multiple streams**
   - Multiple sections stream simultaneously
   - Each section tracked independently
   - All complete successfully

### Manual Testing Checklist

- [ ] Single section streaming shows raw JSON
- [ ] Spinner visible during streaming
- [ ] Auto-scroll works
- [ ] Content transitions to markdown on completion
- [ ] "Run All" streams all sections
- [ ] Refresh during streaming recovers gracefully
- [ ] Mobile layout works

---

## Rollout Plan

1. **Dev Environment:** Enable streaming, test thoroughly
2. **Staging:** Enable with feature flag
3. **Production:**
   - Initially disabled by default
   - Enable for specific tenants
   - Monitor for issues
   - Enable globally

---

## Success Metrics

- [ ] Streaming chunks visible within 500ms of LLM response start
- [ ] No increase in error rates
- [ ] No significant increase in memory usage
- [ ] User feedback positive on "cool" factor
