# Critical Review Prompt: Docling v2 Redesign

**Purpose:** This prompt provides all context needed for an independent agent to critically review the v2 Docling integration redesign for the Medlum medical reporting platform.

---

## Your Mission

You are tasked with **critically reviewing** a proposed architectural redesign of the Docling PDF-to-Markdown integration. Your review should be thorough, skeptical, and identify:

1. **Flaws in the design** - Logical errors, missing edge cases, over-engineering
2. **Gaps in the analysis** - What was missed or glossed over
3. **Implementation risks** - What could go wrong during migration
4. **Alternative approaches** - Better solutions that weren't considered
5. **Practical concerns** - Is this actually implementable in the stated timeline?

Be direct and critical. The goal is to find problems before implementation, not to validate the design.

---

## Required Reading

### Phase 1: Understand the Current Implementation

Read these files to understand what exists today:

#### Core Elixir Integration
```
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum\docling\docling.ex
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum\docling\http.ex
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum\docling\backend.ex
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum\docling\setting.ex
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum\docling\settings.ex
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum\docling\queue.ex
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum\docling\sse_consumer.ex
```

#### Backend Implementations
```
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum\docling\backends\local.ex
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum\docling\backends\remote.ex
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum\docling\backends\vast_ai.ex
```

#### Vast.ai Integration
```
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum\docling\vast_ai\instance_manager.ex
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum\docling\vast_ai\auto_shutdown.ex
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum\docling\vast_ai\activity_tracker.ex
```

#### Web/LiveView Integration
```
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum_web\live\reports_live.ex
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\lib\medlum_web\live\admin\docling_settings_live.ex
```

#### Python Docling Service
```
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docling_service\app\main.py
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docling_service\Dockerfile.gpu
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docling_service\Dockerfile.gpu-base
```

#### Docling Fork (if it exists)
```
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docling\docling\document_converter.py
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docling\pyproject.toml
```

#### Configuration
```
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\config\config.exs
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\config\test.exs
```

#### Scripts
```
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\scripts\docling-ports.env
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\scripts\docling-compose.sh
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docker-compose.yml
```

### Phase 2: Read the Original Analysis

These documents analyzed the current state and identified problems:

```
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\00-overview.md
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\01-elixir-core.md
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\02-docker-deployment.md
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\03-docling-fork.md
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\04-testing.md
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\05-web-liveview.md
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\06-extraction-analysis.md
```

### Phase 3: Review the Proposed Redesign

These are the documents you are critically reviewing:

```
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\v2-redesign\00-redesign-overview.md
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\v2-redesign\01-architecture.md
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\v2-redesign\02-resilience.md
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\v2-redesign\03-telemetry.md
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\v2-redesign\04-testing.md
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\v2-redesign\05-ui-abstraction.md
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\v2-redesign\06-migration-plan.md
```

---

## Context

### What is Medlum?
A medical reporting platform that processes PDF documents (medical records, lab reports, etc.) and converts them to structured markdown for AI-assisted report generation.

### What is Docling?
An open-source Python library (from IBM) that performs PDF-to-markdown conversion with OCR, table extraction, and layout analysis. Medlum uses a forked version with custom telemetry.

### Current Architecture
- 5 backends on ports 8040-8044 (native CPU/GPU, Docker CPU/GPU, Vast.ai cloud)
- Elixir facade wraps Python FastAPI service
- SSE streaming for real-time progress
- Phoenix LiveView for UI
- Oban for background job processing

### Problems Being Addressed
1. **No testability** - Components are tightly coupled, can't mock dependencies
2. **No telemetry** - Framework installed but unused, no metrics
3. **Brittle connections** - No retries, no circuit breakers, hard-coded timeouts
4. **UI coupling** - Backend names, ports, health details leak into user UI

### Proposed Solution (v2)
A clean architecture redesign with:
- Domain layer (value objects, policies)
- Application layer (ConversionService facade)
- Infrastructure layer (backends, resilience, HTTP)
- Complete UI abstraction (users see only "Standard"/"Enhanced")
- Full telemetry and testing infrastructure

---

## Critical Review Questions

Answer these questions in your review:

### Architecture (01-architecture.md)

1. **Is the layer separation correct?**
   - Are there any domain concepts that leaked into infrastructure?
   - Are there infrastructure concerns in the domain layer?
   - Is the service facade too thin or too thick?

2. **Are the abstractions appropriate?**
   - Is `ProcessingProfile` the right abstraction for users?
   - Does `JobStatus` capture all states users need to know?
   - Is hiding backend details from users actually desirable in all cases?

3. **What's missing?**
   - Are there domain concepts not captured?
   - Are there use cases not covered by the proposed API?
   - How does this handle multi-tenant isolation?

4. **Is this over-engineered?**
   - Does this need all these layers for a PDF conversion service?
   - Could a simpler design achieve the same goals?
   - Is the abstraction worth the complexity cost?

### Resilience (02-resilience.md)

5. **Are the resilience patterns correct?**
   - Is the circuit breaker state machine correct?
   - Are the retry policies appropriate for Docling's failure modes?
   - Is the health manager polling frequency appropriate?

6. **What failure modes are missed?**
   - What happens if all backends are unavailable?
   - What happens during Vast.ai provisioning (3-5 minute delay)?
   - How does the circuit breaker interact with the retry policy?

7. **Are the defaults sensible?**
   - 5 failures to trip circuit breaker - too few? too many?
   - 30 second circuit timeout - appropriate?
   - 3 retries with exponential backoff - correct for 20-minute jobs?

8. **Performance implications**
   - Does the circuit breaker add latency to happy path?
   - Does health checking create too much background load?
   - Is the connection pool sized correctly?

### Telemetry (03-telemetry.md)

9. **Is the telemetry complete?**
   - Are there operations that should emit events but don't?
   - Is the event naming consistent and discoverable?
   - Are the measurements useful for debugging?

10. **Is the telemetry practical?**
    - Will the volume of events be manageable?
    - Are the Prometheus queries correct?
    - Will the alert rules trigger appropriately?

11. **What about distributed tracing?**
    - How do traces propagate to the Python service?
    - How do you correlate Elixir and Python logs?
    - Is the correlation ID scheme sufficient?

### Testing (04-testing.md)

12. **Are the test patterns correct?**
    - Do the mocks accurately represent backend behavior?
    - Are there race conditions in the mock implementations?
    - Is the property-based test actually valid?

13. **What's not tested?**
    - Integration with real Docling service
    - Vast.ai provisioning flow
    - Multi-tenant scenarios
    - Large file handling

14. **Is 90% coverage achievable?**
    - Are there parts of the code that are hard to test?
    - What about testing the SSE stream?
    - What about testing the circuit breaker timing?

### UI Abstraction (05-ui-abstraction.md)

15. **Is hiding everything correct?**
    - Should power users be able to see which backend processed their document?
    - What happens when a user reports a problem - how do you debug?
    - Is "Enhanced unavailable" enough information?

16. **Migration concerns**
    - How do you migrate users with `docling_backend: :vast_ai` preference?
    - What happens to documents that have `backend: "docker_cpu"` in metadata?
    - Is the database migration safe for rollback?

17. **Are the components complete?**
    - Error states?
    - Loading states?
    - Accessibility?

### Migration Plan (06-migration-plan.md)

18. **Is the timeline realistic?**
    - Can phase 2 (resilience) really be done in one week?
    - How much testing time is built in?
    - What if phases slip?

19. **What are the risks?**
    - What's the riskiest phase?
    - What's the rollback plan if phase 5 fails after removing old code?
    - How do you handle in-flight jobs during migration?

20. **Is the feature flag approach correct?**
    - How do you handle jobs that span the flag change?
    - How do you test both paths in CI?
    - What's the plan if v2 has subtle bugs that only appear at scale?

---

## Specific Code Review Points

When reading the proposed code in the design docs, check:

### CircuitBreaker (02-resilience.md)

```elixir
# Is this state machine correct?
# What happens if GenServer crashes while circuit is open?
# Is the ETS table approach better than GenServer state?
# Should circuit breaker state be persistent across restarts?
```

### RetryPolicy (02-resilience.md)

```elixir
# Is the jitter implementation correct?
# What happens if the function being retried has side effects?
# Should there be a way to cancel retries in progress?
```

### MockBackend (04-testing.md)

```elixir
# Is Agent the right choice for test state?
# What happens with concurrent tests?
# Should reset() be automatic in setup?
```

### Service (01-architecture.md)

```elixir
# Is JobTracker.register() transactional with BackendRouter.route()?
# What happens if job is registered but routing fails?
# How do you clean up orphaned jobs?
```

---

## Your Deliverable

Write a comprehensive review document that includes:

1. **Executive Summary** - Overall assessment (proceed/revise/reject)

2. **Critical Issues** - Problems that must be fixed before implementation
   - Severity (blocking, major, minor)
   - Specific location in the design
   - Proposed fix

3. **Design Concerns** - Issues with the approach
   - What's over-engineered
   - What's under-specified
   - What's missing

4. **Implementation Risks** - What could go wrong
   - Technical risks
   - Timeline risks
   - Rollback risks

5. **Alternative Approaches** - Different ways to solve the problems
   - Simpler alternatives
   - Different architectural patterns
   - Industry best practices

6. **Recommendations** - Prioritized list of changes
   - Must fix
   - Should fix
   - Nice to have

7. **Questions for the Author** - Things that need clarification

---

## Output Location

Write your review to:
```
\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docs\20251126\docling-research\v2-redesign\REVIEW-RESPONSE.md
```

---

## Important Notes

- Be skeptical. The author may have overlooked obvious problems.
- Consider the real-world context: this is a medical reporting platform where reliability matters.
- Think about what happens when things go wrong, not just the happy path.
- Consider developer experience: will engineers actually want to work with this code?
- Consider operational experience: will this be debuggable in production?
- Don't just find problems - propose solutions.
