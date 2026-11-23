# LLM Architecture Cleanup

Design documents for addressing architectural issues discovered during rate limiting investigation.

## Context

Investigation into why `max_concurrency_per_model: 1` wasn't being respected revealed multiple architectural smells in how medlum handles LLM operations.

## Documents

| # | Title | Priority | Complexity | Dependencies |
|---|-------|----------|------------|--------------|
| 01 | [Oban/Rate Limiter Alignment](01_oban_rate_limiter_alignment.md) | **Critical** | Low | None |
| 02 | [Unified LLM Entry Point](02_unified_llm_entry_point.md) | High | Medium | 01 |
| 03 | [Explicit Rate Limiting](03_explicit_rate_limiting.md) | High | Medium | 02 |
| 04 | [Application-Level Gate](04_application_level_gate.md) | Medium | Medium | None |
| 05 | [Stream Flag Validation](05_stream_flag_validation.md) | Medium | Low | None |
| 06 | [Central Model Registry](06_central_model_registry.md) | Low | Low | None |
| 07 | [LLM Telemetry](07_llm_telemetry.md) | Medium | Medium | None |
| 08 | [Reports LiveView State](08_reports_live_state_consolidation.md) | Medium | High | None |

## Recommended Order

### Immediate (Before gemini_ex 0.7.2)

1. **01 - Oban/Rate Limiter Alignment** - Set `reports: 1` as temporary fix

### After gemini_ex 0.7.2

2. **04 - Application-Level Gate** - Defense in depth
3. **02 - Unified LLM Entry Point** - Single code path
4. **03 - Explicit Rate Limiting** - Make dependency visible

### Ongoing Improvements

5. **07 - LLM Telemetry** - Observability
6. **05 - Stream Flag Validation** - API cleanup
7. **06 - Central Model Registry** - Configuration cleanup
8. **08 - Reports LiveView State** - UI state management

## External Dependencies

- **gemini_ex 0.7.1** - Rate limiter hardening (in progress)
- **gemini_ex 0.7.2** - Streaming rate limiter integration (planned)

See also:
- `/home/home/p/g/n/gemini_ex/docs/20251205/rate_limiting/gemini_rate_limiting_and_model_aliases.md`
- `/home/home/p/g/n/gemini_ex/docs/20251205/rate_limiting/streaming_rate_limiter_integration.md`

## Success Criteria

After implementing all documents:

1. `max_concurrency_per_model: N` is respected for both streaming and batch
2. Rate limit events visible in LiveDashboard
3. Single code path for LLM calls regardless of mode
4. No scattered model strings
5. ReportsLive state is predictable and consistent
