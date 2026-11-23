# 01: Oban Queue / Rate Limiter Alignment

## Problem

```elixir
# config/config.exs:142
queues: [ingestion: 5, reports: 5, ...]

# config/config.exs:184
max_concurrency_per_model: 1
```

Oban's `:reports` queue spawns 5 concurrent workers, but gemini_ex rate limiter is configured for 1 concurrent request per model. These configs are:

1. In different places (Oban config vs gemini_ex config)
2. Not documented as related
3. Semantically contradictory

When streaming bypasses the rate limiter (see gemini_ex 0.7.2 fix), all 5 workers fire simultaneously, causing 429s.

## Current Behavior

1. User triggers "Run All Sections" with 13 sections
2. `Reports.run_sections/6` enqueues 13 Oban jobs to `:reports` queue
3. Oban immediately dispatches 5 workers (queue limit)
4. Each worker calls `SectionRunner.run_section_streaming/5`
5. Streaming path bypasses rate limiter
6. 5 concurrent requests hit Gemini API
7. 429 errors on 3 of them

## Proposed Solution

### Option A: Align at Oban Level (Recommended Short-Term)

```elixir
# config/config.exs
queues: [
  ingestion: 5,
  reports: 1,  # Match rate limiter concurrency
  health_checks: 1,
  maintenance: 1
]
```

**Pros:**
- Simple, immediate fix
- Works even before gemini_ex 0.7.2
- No code changes

**Cons:**
- Serializes all report sections (slower total time)
- Doesn't leverage rate limiter's adaptive concurrency

### Option B: Remove Oban Concurrency Limit

```elixir
queues: [
  ingestion: 5,
  reports: 50,  # High limit, let rate limiter control
  health_checks: 1,
  maintenance: 1
]
```

**Pros:**
- Rate limiter handles concurrency dynamically
- Can scale up when API allows

**Cons:**
- Requires gemini_ex 0.7.2 streaming fix first
- More Oban job overhead

### Option C: Document and Link Configs

```elixir
# config/config.exs

# IMPORTANT: These two settings must be coordinated.
# Oban queue concurrency should not exceed gemini rate limiter concurrency
# unless you want requests to queue at the rate limiter level.
#
# Current strategy: Let Oban spawn workers freely, rate limiter gates API calls.
# If you see 429s, reduce reports queue or increase max_concurrency_per_model.

config :medlum, Oban,
  queues: [
    ingestion: 5,
    # reports: Should align with gemini_ex max_concurrency_per_model
    # Currently: 5 workers, but only 1 concurrent API call allowed
    reports: 5,
    health_checks: 1,
    maintenance: 1
  ]

# See: Oban queues above - these must be coordinated
config :gemini_ex, :rate_limiter,
  max_concurrency_per_model: 1,
  # ...
```

## Implementation

### Phase 1: Immediate Fix (Before gemini_ex 0.7.2)

1. Change `reports: 5` to `reports: 1`
2. Add comment explaining the relationship
3. Monitor section run times

### Phase 2: After gemini_ex 0.7.2

1. Restore `reports: 5` (or higher)
2. Let rate limiter handle concurrency
3. Add telemetry to monitor queue depth vs API concurrency

## Files to Modify

- `config/config.exs` - Queue and rate limiter configs

## Testing

1. Run full report with 13 sections
2. Verify no 429 errors
3. Measure total completion time
4. Compare before/after metrics

## Rollback

Revert `reports:` value in config.exs.
