# Critical Analysis: Medlum Docling System

**Date:** November 28, 2025
**Status:** SYSTEM FUNDAMENTALLY BROKEN
**Recommendation:** REBUILD FROM SCRATCH

---

## Executive Summary

The Medlum Docling/PDF processing system is **architecturally broken at multiple levels**. After comprehensive multi-agent analysis, we've identified:

- **5 redundant backends** when 2 would suffice
- **Dead code paths** (v2 profile system is defined but never implemented)
- **Orphaned message channels** (progress broadcasts go nowhere)
- **Zero Docker automation** (manual container management required)
- **No real auto-boot** (Vast.ai requires manual admin provisioning)
- **4 layers of configuration indirection** creating maintenance nightmare

**Bottom line:** Users cannot reliably upload PDFs and see results. The system has never worked correctly.

---

## Part 1: The V2 System is a Phantom

### What Was Claimed
The v2 conversion system documentation (`V2_CONVERSION_SYSTEM_TECHNICAL_REFERENCE.md`) describes:
- `Conversion.Service` - Job submission
- `Conversion.Job` - Job tracking
- `Conversion.ProcessingProfile` - Profile-based routing
- `Conversion.BackendRouter` - Backend selection

### What Actually Exists
**NONE OF THESE MODULES EXIST.**

The schema in `lib/medlum/docling/setting.ex` (lines 54-60) defines:
```elixir
field(:v2_profile_backends, :map,
  default: %{
    "standard" => ["docker_cpu", "local_cpu"],  # TYPO: local_cpu doesn't exist
    "enhanced" => ["docker_gpu", "local_gpu", "cloud"]  # TYPO: local_gpu doesn't exist
  }
)
```

This field is **STORED but NEVER USED**. The `resolve_docling_backend/1` function in `documents.ex` ignores it entirely.

### Impact
- Profile selection in UI does nothing
- "Enhanced" vs "Standard" are meaningless labels
- Backend routing falls through to hardcoded defaults

---

## Part 2: Ingestion System Has Dead Message Channel

### The Fatal Flaw
`lib/medlum/documents.ex` broadcasts job progress to PubSub:
```elixir
PubSub.broadcast(
  MedlumWeb.PubSub,
  "ingestion-job:#{job_id}",
  {:job_progress, record_set_id, payload}
)
```

**But `reports_live.ex` has NO HANDLER for `:job_progress` messages.**

Line 984 catches all unhandled messages:
```elixir
def handle_info(_message, socket), do: {:noreply, socket}
```

All progress updates are **silently discarded**.

### What Users Experience
1. Upload PDF → HTTP 200 (success)
2. File appears in list with status "queued"
3. Progress stays at 0% forever
4. Backend processes job, sends 30+ progress messages
5. All messages ignored by UI
6. User refreshes page after 10 minutes
7. Status suddenly shows "completed" or "failed"

### Root Cause
The UI subscribes to **conversion jobs** (v2 Service) but NOT **ingestion jobs** (v1 worker). Two incompatible systems exist in parallel.

---

## Part 3: Docker Container Management is Manual

### Current State
To use Docling locally, admin must:

1. SSH into server
2. Run `./scripts/docling-compose.sh`
3. Select option from interactive menu
4. Wait for container to start
5. Start Phoenix app separately
6. Later, manually stop container

### What's Missing
- **No auto-start on app boot** - Container must be pre-running
- **No wait-for-ready** - App may start before Docling is healthy
- **No auto-restart on crash** - Docker policy helps, but 10-30s gap
- **No graceful shutdown** - Containers orphaned on app stop

### Why This Design?
The team assumed:
- Docling is an external service (like a database)
- Admins should have explicit control
- Containers should persist across app restarts

**Valid for enterprise. Terrible for development and single-server deployment.**

---

## Part 4: Vast.ai "Auto-Boot" Doesn't Exist

### What Was Claimed
"Auto-boot" implies: User uploads PDF → System provisions GPU instance → Job runs

### What Actually Happens
1. Admin runs `mix vast_ai.provision` (one-time CLI command)
2. Instance is created, runs, eventually stops due to idle
3. User uploads PDF
4. `InstanceManager.ensure_instance()` is called
5. If stopped instance exists → starts it (this works)
6. **If NO instance exists → returns error** (no auto-provision)

### The Missing Provisioner
`instance_manager.ex` lines 1313-1348:
```elixir
defp maybe_provision_instance(config, state) do
  provisioner = Keyword.get(config, :provisioner)  # NEVER CONFIGURED
  cond do
    is_function(provisioner, 0) -> provisioner.()  # NEVER EXECUTES
    true -> :skip  # ALWAYS RETURNS THIS
  end
end
```

The architecture supports on-demand provisioning, but **no provisioner function is configured**.

---

## Part 5: 5 Backends is Over-Engineering

### Current Backend Matrix
| Port | Name | Type | GPU |
|------|------|------|-----|
| 8040 | native_cpu | Host Python | No |
| 8041 | native_gpu | Host Python | Yes |
| 8042 | docker_cpu | Docker | No |
| 8043 | docker_gpu | Docker | Yes |
| 8044 | vast_ai | Cloud | Yes |

### Reality Check
From Docling's perspective, these are **all identical HTTP endpoints**. The differences are:
- Where Python runs (host vs container vs cloud)
- Whether GPU is available

This is **configuration complexity**, not architectural necessity.

### What Users Need
- **Local option** - Free, works offline, CPU or GPU if available
- **Cloud option** - Premium, fast, always GPU

Two options. Not five.

---

## Part 6: Configuration Layers Create Chaos

### Layer 1: Database Schema
`docling_settings` table with 20+ fields including:
- 5 URL fields (one per backend)
- Legacy fields (`backend`, `local_url`, `remote_url`)
- V2 fields (`v2_profile_backends`)
- Cloud fields (`cloud_api_key`, etc.)

### Layer 2: Admin UI
Manual input for all 5 backend URLs, mode selection, active backend selection.

### Layer 3: BackendRouter
Maps profiles to backend lists (using v2_profile_backends that nothing else uses).

### Layer 4: HealthManager
Checks health of ALL 5 backends every 30 seconds, even though only 1 is active.

### Layer 5: InstanceManager
1487-line GenServer managing Vast.ai lifecycle with:
- 4-state machine
- Activity tracking
- Tunnel management
- SSH commands
- Auto-shutdown

### The Problem
A single config change requires understanding 5 layers. Testing requires all 5 to be in sync.

---

## Part 7: Error Handling is Silent

### Broadcast to Nobody
When ingestion fails:
```elixir
Documents.record_job_stage!(
  job,
  "failed",
  message: "Docling ingestion failed: #{error_message}",
  upload_status: "failed"
)
```

This broadcasts to `"ingestion-job:#{job_id}"` which **nobody listens to**.

### User Experience
- Upload appears to work
- Progress stuck at 0%
- No error message shown
- User waits 20 minutes (default timeout)
- Page refresh shows "failed" with generic message

### Missing: Real-Time Error Display
The infrastructure exists (PubSub) but the connection is broken.

---

## Part 8: Timeouts Create False Hangs

### Default Configuration
- Conversion timeout: **20 minutes** (`@default_conversion_timeout_ms 1_200_000`)
- Stale job threshold: **30 minutes**
- Max retries: 3 (each with 20-minute timeout)

### Total Possible Wait Time
20 min × 3 retries + 30 min stale detection = **90+ minutes** before system admits failure.

### User Perception
"The system is broken" (it's actually just waiting for timeout).

---

## Summary: Why It's "A Flaming Pile of Shit"

| Issue | Severity | Impact |
|-------|----------|--------|
| V2 profile system is phantom code | CRITICAL | Routing doesn't work |
| Progress messages go nowhere | CRITICAL | UI never updates |
| No Docker automation | HIGH | Manual intervention required |
| No real auto-boot for Vast.ai | HIGH | Cloud requires admin provisioning |
| 5 redundant backends | MEDIUM | Configuration complexity |
| 4 layers of config indirection | MEDIUM | Maintenance nightmare |
| Silent error handling | HIGH | Users don't know what failed |
| 20-minute timeouts | MEDIUM | False perception of broken system |

---

## Conclusion

This system needs to be **rebuilt from scratch** with:

1. **Two backends only**: Local (auto-managed Docker) + Cloud (true auto-boot)
2. **Unified configuration**: One source of truth
3. **Real-time progress**: UI subscribes to job updates
4. **Automatic Docker management**: Start/stop with app
5. **True auto-boot for cloud**: Provision on demand
6. **Fast timeouts**: 2-5 minutes, not 20
7. **Clear error messages**: Show failures immediately

See `02-SIMPLIFIED-ARCHITECTURE.md` for the rebuild proposal.
