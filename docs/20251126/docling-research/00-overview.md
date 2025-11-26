# Docling Integration Research - Executive Summary

**Date:** November 26, 2025
**Project:** Lumainus Medical Reporting Platform
**Focus:** Docling PDF-to-Markdown Integration Analysis

---

## Overview

This research documents the Docling integration within the Lumainus medical reporting platform, analyzing the architecture, deployment infrastructure, and potential for extraction as a standalone service.

## Document Index

| File | Description |
|------|-------------|
| [01-elixir-core.md](01-elixir-core.md) | Core Elixir service architecture and API |
| [02-docker-deployment.md](02-docker-deployment.md) | Docker, scripts, and deployment infrastructure |
| [03-docling-fork.md](03-docling-fork.md) | Docling Python fork with telemetry extensions |
| [04-testing.md](04-testing.md) | Testing infrastructure and patterns |
| [05-web-liveview.md](05-web-liveview.md) | Phoenix LiveView and web integration |
| [06-extraction-analysis.md](06-extraction-analysis.md) | Extraction feasibility with pros/cons |

---

## Architecture Summary

### Multi-Backend System

The Docling integration supports **5 standardized backends** on ports 8040-8044:

```
+------------+----------+--------+------+--------+
| Port       | Backend  | Type   | GPU  | Cost   |
+------------+----------+--------+------+--------+
| 8040       | native_cpu | Local  | No   | Free   |
| 8041       | native_gpu | Local  | Yes  | Free   |
| 8042       | docker_cpu | Docker | No   | Free   |
| 8043       | docker_gpu | Docker | Yes  | Free   |
| 8044       | vast_ai    | Cloud  | Yes  | $/hr   |
+------------+----------+--------+------+--------+
```

### Layer Architecture

```
+------------------------------------------+
|        Phoenix LiveView (Web UI)         |
|    ReportsLive, DoclingSettingsLive      |
+------------------------------------------+
|       Lumainus.Docling (Facade)          |
|    Unified API, Backend Resolution       |
+------------------------------------------+
|           Backend Modules                |
|  Local | Remote | VastAI (Backends/)     |
+------------------------------------------+
|        Lumainus.Docling.HTTP             |
|    Shared HTTP Client, SSE, Polling      |
+------------------------------------------+
|          Docling Services                |
|  FastAPI (docling_service/app/main.py)   |
+------------------------------------------+
|       Docling Fork (Python)              |
|    Progress callbacks, telemetry         |
+------------------------------------------+
```

### Key Components

1. **Elixir Facade** (`lib/lumainus/docling.ex`)
   - Unified API: `convert/2`, `enqueue/2`, `await/2`, `health/1`
   - Backend resolution and configuration
   - 600+ lines of production code

2. **Docker Infrastructure** (`docling_service/`)
   - Two-layer build: Base image (15GB) + App image (1.5GB)
   - FastAPI service with job queue and SSE streaming
   - Scripts for compose, GPU management, Vast.ai provisioning

3. **Python Fork** (`docling/`)
   - Extended Docling 2.63.0 with progress callbacks
   - Real-time telemetry for page-by-page progress
   - Maintained in sync with upstream

4. **Web Integration**
   - Admin UI for backend configuration
   - Real-time progress via PubSub/SSE
   - User preference (local vs cloud mode)

---

## Key Findings

### Strengths

1. **Well-Abstracted Architecture**
   - Clean separation between facade, backends, and HTTP layer
   - Behavior-based polymorphism allows easy backend additions
   - Configuration can come from env, DB, or code

2. **Production-Ready Infrastructure**
   - Comprehensive Docker/deployment tooling
   - Cost optimization via auto-shutdown
   - Health monitoring with Oban cron jobs

3. **Real-Time Progress**
   - SSE-first with polling fallback
   - Progress callbacks in Python fork
   - PubSub integration for LiveView updates

4. **Flexible Deployment**
   - 4 local options (native/Docker, CPU/GPU)
   - Cloud option with auto-provisioning
   - User mode abstraction (local vs cloud)

### Challenges for Extraction

1. **Deep Lumainus Integration**
   - Database schemas tied to multi-tenant model
   - PubSub channels use Lumainus-specific topics
   - Configuration merging uses Lumainus settings

2. **Cross-Cutting Concerns**
   - Vast.ai provisioning intertwined with settings
   - Health checks integrated with Oban queues
   - Job processing tied to IngestionJob schema

3. **Python Fork Maintenance**
   - Must track upstream Docling releases
   - Telemetry extensions need testing with updates
   - Model version compatibility

---

## Recommendations

### For Extraction as Standalone Service

See [06-extraction-analysis.md](06-extraction-analysis.md) for detailed analysis.

**Summary:**
- Feasible to extract core HTTP/backend layer
- Would require new configuration system
- Testing infrastructure is already well-isolated
- Estimated effort: 2-4 weeks for MVP

### For Improved Testing

See [04-testing.md](04-testing.md) for detailed analysis.

**Key gaps:**
- SSE streaming not tested (uses `prefer_sse: false`)
- Integration tests skipped in CI
- No property-based tests

### For Documentation

This research provides comprehensive documentation. Consider:
- Adding architecture diagrams to README
- Creating API reference from this research
- Documenting deployment procedures

---

## File Locations

### Elixir Source
```
lib/lumainus/docling/
├── docling.ex              # Main facade
├── setting.ex              # DB schema
├── settings.ex             # Settings service
├── backend.ex              # Behavior definition
├── http.ex                 # HTTP client
├── queue.ex                # Job queue facade
├── sse_consumer.ex         # SSE handling
├── health_check.ex         # Health schema
├── health_check_worker.ex  # Oban worker
├── backends/
│   ├── local.ex            # Local backend
│   ├── remote.ex           # Remote backend
│   └── vast_ai.ex          # Cloud backend
└── vast_ai/
    ├── instance_manager.ex # Instance lifecycle
    ├── activity_tracker.ex # Usage tracking
    ├── auto_shutdown.ex    # Cost control
    └── provisioning_state.ex
```

### Python/Docker
```
docling/                    # Docling fork
docling_service/            # FastAPI service
├── app/main.py            # FastAPI app
├── Dockerfile.gpu         # App image
├── Dockerfile.gpu-base    # Base image
└── run.sh                 # Startup script

scripts/
├── docling-ports.env      # Port definitions
├── docling-compose.sh     # Docker Compose menu
├── docling-gpu.sh         # Image build menu
├── docling-vast.sh        # Vast.ai menu
└── setup_docling_service.sh
```

### Tests
```
test/lumainus/docling/
├── docling_test.exs
├── http_test.exs
├── health_check_worker_test.exs
├── backends/
│   ├── local_test.exs
│   ├── remote_test.exs
│   └── vast_ai_test.exs
└── vast_ai/
    └── instance_manager_test.exs
```

---

## Next Steps

1. **Review extraction analysis** in [06-extraction-analysis.md](06-extraction-analysis.md)
2. **Assess testing gaps** in [04-testing.md](04-testing.md)
3. **Decide on extraction scope** (full service vs library)
4. **Plan integration points** for external consumers
