# Docling Docker and Deployment Infrastructure

**Date:** November 26, 2025
**Component:** `docling_service/`, `scripts/`, `docker-compose.yml`

---

## Overview

The Lumainus project implements a sophisticated Docling PDF-to-Markdown conversion system with **5 standardized backends** organized into two user-facing deployment modes:
- **Local Mode** (free): 4 backends running on the host or in Docker
- **Cloud Mode** ($$$): Vast.ai GPU instances

All backends are standardized on ports **8040-8044** with a unified Elixir API layer.

---

## Directory Structure

```
lumainus/
├── docling/                          # Fork of Docling library (Python)
│   ├── Dockerfile                    # Base image definition
│   ├── docling/                      # Python source
│   ├── scripts/                      # Build/test helpers
│   └── pyproject.toml               # Dependencies
│
├── docling_service/                  # FastAPI REST microservice (Python)
│   ├── app/
│   │   └── main.py                  # FastAPI app (job queue, SSE streaming)
│   ├── Dockerfile.gpu               # Thin app image (inherits from base)
│   ├── Dockerfile.gpu-base          # Heavy base (PyTorch + models)
│   ├── requirements.txt             # Python deps
│   ├── run.sh                       # Bootstrap script (venv, pip, uvicorn)
│   ├── build-gpu-image.sh          # Build both Dockerfiles
│   ├── README.md                    # Microservice docs
│   └── DEPLOYMENT.md                # Full deployment guide
│
├── scripts/
│   ├── docling-ports.env            # Single source of truth (ports + helpers)
│   ├── docling-compose.sh           # Interactive docker compose menu
│   ├── docling-gpu.sh               # Interactive image build/push menu
│   ├── docling-vast.sh              # Interactive Vast.ai provisioning menu
│   ├── setup_docling_service.sh     # Native (non-Docker) setup
│   ├── vast_ai_cleanup.sh           # Auto-shutdown idle instances
│   ├── vast_caddy_onstart.sh        # HTTPS reverse proxy for Vast instances
│   └── vast_*                       # Other Vast utilities
│
├── docker-compose.yml               # Services for docker_cpu & docker_gpu
└── config/config.exs                # Default URLs, timing, auto-shutdown config
```

---

## Port Allocation Scheme (8040-8044)

Centralized in `/scripts/docling-ports.env` with bash helper functions:

| Port | Backend | Type | Runtime | GPU | Cost |
|------|---------|------|---------|-----|------|
| **8040** | `native_cpu` | Host Process | Python/uvicorn | No | Free |
| **8041** | `native_gpu` | Host Process | Python/uvicorn + CUDA | Yes | Free |
| **8042** | `docker_cpu` | Container | Docker (CPU mode) | No | Free |
| **8043** | `docker_gpu` | Container | Docker (--gpus all) | Yes | Free |
| **8044** | `vast_ai` | Cloud VM | Vast.ai GPU instance | Yes | $/hr |

Each backend uses the same FastAPI service code (`docling_service/app/main.py`). The difference is only the runtime environment and model availability.

---

## Docker Architecture

### Two-Layer Docker Build Strategy

**Problem:** Docling models are ~8-10 GB. Need fast rebuild cycle.

**Solution:** Two separate Dockerfiles

#### 1. Base Image: `Dockerfile.gpu-base` (~20GB final, ~15 min build)

```dockerfile
FROM pytorch/pytorch:2.2.2-cuda12.1-cudnn8-runtime
# Install: FastAPI, uvicorn, local docling fork
# Download models by initializing DocumentConverter
# Result: ghcr.io/nshkrdotcom/lumainus-docling-base:latest
```

- **Frequency:** Rebuild ~monthly when Docling or PyTorch versions change
- **Size:** ~15-20 GB (includes PyTorch + pre-downloaded models)
- **Models cached at:** `/app/models/huggingface` and `/app/models/torch`

#### 2. App Image: `Dockerfile.gpu` (~1.5GB delta, ~2 min rebuild)

```dockerfile
FROM ghcr.io/nshkrdotcom/lumainus-docling-base:latest
# Copy only: docling_service/app (FastAPI code)
# CMD: uvicorn app.main:app --port ${PORT}
```

- **Frequency:** Rebuild every code change in `docling_service/app`
- **Size:** ~1-2 GB additional (tiny payload, fast push)
- **Inherits:** All 8-10 GB of pre-downloaded models from base

### Docker Compose Services

**File:** `docker-compose.yml`

```yaml
services:
  docling-cpu:  # CPU container, port 8042
    image: ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest
    environment:
      - CUDA_VISIBLE_DEVICES=  # Disable GPU
      - PORT=8042
    resources:
      limits: { memory: 8G }
      reservations: { memory: 2G }

  docling-gpu:  # GPU container, port 8043 (requires nvidia-docker)
    image: ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest
    profiles: [gpu]  # Only started with --profile gpu
    environment:
      - CUDA_VISIBLE_DEVICES=0
      - PORT=8043
      - OMP_NUM_THREADS=4
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

---

## Deployment Scripts

### 1. `docling-ports.env` - Port Allocation Source of Truth

**File:** `scripts/docling-ports.env`

Exports environment variables used everywhere:
- Port variables: `DOCLING_PORT_NATIVE_CPU`, `DOCLING_PORT_NATIVE_GPU`, etc.
- URL variables: `DOCLING_URL_DOCKER_CPU`, etc.
- **Helper functions:**
  - `docling_port_for <backend>` - Returns port for backend name
  - `docling_url_for <backend>` - Returns URL for backend name
  - `docling_is_gpu <backend>` - Checks if GPU required
  - `docling_is_cloud <backend>` - Checks if cloud ($$)
  - `docling_local_backends` - Lists all local backends
  - `docling_print_ports` - Pretty-print port table

All scripts source this file: `source "$SCRIPT_DIR/docling-ports.env"`

### 2. `setup_docling_service.sh` - Native (Non-Docker) Installation

**File:** `scripts/setup_docling_service.sh`

Provisions Docling to run directly on the host OS (no Docker).

**Modes:**
```bash
./setup_docling_service.sh native_cpu   # Port 8040, CPU only
./setup_docling_service.sh native_gpu   # Port 8041, with CUDA
```

**What it does:**
1. Installs system deps: Python 3, build tools, libgl1, tesseract
2. If GPU: Installs nvidia-cuda-toolkit, checks nvidia-smi
3. Creates `.venv` in docling_service/
4. Installs Python deps (FastAPI, uvicorn, local Docling fork)
5. Runs `./run.sh` which starts uvicorn

### 3. `docling-compose.sh` - Docker Compose Interactive Menu

**File:** `scripts/docling-compose.sh`

Wrapper around `docker compose` with 24-option interactive menu:

```
START SERVICES
  1) Start CPU service only
  2) Start GPU service only
  3) Start BOTH services
  4-5) Foreground (attached) mode

STOP SERVICES
  6-9) Stop individual or all services

STATUS & LOGS
  10-14) ps, logs, health checks

HEALTH & TEST
  15-17) Health checks for CPU/GPU/BOTH

MANAGEMENT
  18-20) Restart services
  21-22) Pull/build latest images

AUTO-START ON REBOOT
  23-24) Enable/disable restart: always
```

### 4. `docling-gpu.sh` - Docker Image Build & Registry Manager

**File:** `scripts/docling-gpu.sh`

Interactive menu (24 options) for building, testing, and publishing Docker images.

**Key operations:**
```
BUILD
  1) Build BASE image (slow, ~15 min)
  2) Build APP image (fast, ~2 min)
  3) Build BOTH

RUN CONTAINERS
  4-6) Run/stop docker_cpu and docker_gpu

HEALTH & TEST
  10-14) Health checks, PDF conversion test, logs

REGISTRY
  16-19) Login to ghcr.io, push BASE/APP

CLEANUP
  23-24) Remove images, prune Docker
```

**Configuration:**
```bash
BASE_IMAGE_NAME=ghcr.io/nshkrdotcom/lumainus-docling-base
FULL_IMAGE=ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest
```

### 5. `docling-vast.sh` - Vast.ai Cloud GPU Provisioning

**File:** `scripts/docling-vast.sh`

Interactive menu (19 options) for provisioning and managing Vast.ai GPU instances.

**Key operations:**
```
INSTANCE MANAGEMENT
  1-6) List, provision, destroy instances

DEPLOYMENT
  7-10) Deploy, health check, logs, restart (via SSH)

SEARCH & OFFERS
  11-14) Search GPUs, find cheap offers

CONFIGURATION
  15-17) Set API key, show defaults, test connection

PHOENIX INTEGRATION
  18-19) Update cloud_url in Phoenix config, health check
```

**Configuration:**
```bash
DEFAULT_MAX_PRICE="0.25"          # $/hr
DEFAULT_DISK_GB="16"
DEFAULT_GEOLOCATION="US,CA"
DEFAULT_GPU_TYPE="RTX_3090"
DEFAULT_LABEL="docling-lumainus"
```

### 6. `vast_ai_cleanup.sh` - Idle GPU Instance Killer

**File:** `scripts/vast_ai_cleanup.sh`

Automatic cost control: Destroys idle Vast.ai instances after timeout.

```bash
./scripts/vast_ai_cleanup.sh              # Check & cleanup
./scripts/vast_ai_cleanup.sh --dry-run    # Preview only
./scripts/vast_ai_cleanup.sh --timeout 30 # Override timeout (mins)
```

### 7. `vast_caddy_onstart.sh` - HTTPS Reverse Proxy Setup

**File:** `scripts/vast_caddy_onstart.sh`

Runs on Vast.ai instance at startup to set up automatic HTTPS.

---

## FastAPI Microservice: `docling_service/app/main.py`

**Framework:** FastAPI 0.115+, Uvicorn, Python 3.10+

### Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/health` | GET | Service heartbeat |
| `/convert` | POST | Synchronous PDF conversion |
| `/jobs` | POST | Enqueue async conversion job |
| `/jobs/{id}/status` | GET | Poll job status |
| `/jobs/{id}/stream` | GET | SSE stream of job progress |

### Job Queue System

**In-memory queue:** `asyncio.Queue[ConversionJob]`

**Job states:**
- `pending` - Waiting in queue
- `processing` - Worker actively converting
- `completed` - Done (success)
- `failed` - Error occurred

**Streaming:** Server-Sent Events (SSE) with job progress, page counts, GPU device info.

### Convert Response

```json
{
  "success": true,
  "markdown": "## Report...",
  "metadata": {
    "page_count": 5,
    "source_kind": "upload",
    "has_tables": true
  },
  "pages": [
    {
      "page_number": 1,
      "text": "...",
      "markdown": "...",
      "cells": [...],
      "segments": [...]
    }
  ]
}
```

---

## Local vs. Cloud Deployment Differences

### Local Mode (Free)

**User chooses one of 4 backends via admin UI:**

1. **native_cpu** (Port 8040)
   - Setup: `./setup_docling_service.sh native_cpu`
   - Runs on host, no Docker
   - ~2-5 min first page, ~30 sec per page

2. **native_gpu** (Port 8041)
   - Setup: `./setup_docling_service.sh native_gpu`
   - Requires NVIDIA driver + CUDA
   - ~30 sec first page, ~5-10 sec per page

3. **docker_cpu** (Port 8042)
   - Start: `./docling-compose.sh` option 1
   - Container-based, CPU mode
   - Portable, reproducible

4. **docker_gpu** (Port 8043)
   - Start: `./docling-compose.sh` option 3
   - Requires `nvidia-docker`
   - Same speed as native_gpu

### Cloud Mode ($$$)

**User elects to pay for Vast.ai GPU:**

1. **Auto-provisioning** (Admin UI `/admin/vast_ai`):
   - Search offers: `RTX 3090`, `RTX 4090`, filters by price
   - Click "Provision"
   - Creates instance with custom image
   - Sets up HTTPS via Caddy
   - Updates `setting.cloud_url` in DB

2. **Auto-shutdown**:
   - Cron job runs every 5 min
   - Destroys if idle > 30 min

**Cost comparison:**
- **Local:** Free (your hardware)
- **Cloud RTX 3090:** ~$0.20/hr
- **Cloud RTX 4090:** ~$0.35/hr

---

## Vast.ai Integration Architecture

### Elixir Vast.ai Modules

**Location:** `lib/lumainus/docling/vast_ai/`

#### Instance Manager (`instance_manager.ex`)
- `provision_with_offers/3` - Create instance from offer
- `wait_for_ready/2` - Poll for SSH connectivity
- `destroy/1` - Tear down instance
- `health_check/1` - Test service endpoint
- `sync_state_from_vast/0` - Reconcile DB with Vast API

#### Auto-Shutdown (`auto_shutdown.ex`)
- Cost control mechanism
- Destroys idle instances after configurable timeout
- **Elixir config:**
  ```elixir
  config :lumainus, :vast_ai_auto_shutdown,
    enabled: true,
    check_interval_minutes: 5,
    idle_timeout_minutes: 30
  ```

---

## Build & Deployment Steps

### Quick Start: Local Docker CPU

```bash
cd lumainus/

# 1. Build images locally
./scripts/docling-gpu.sh build
# -> Builds base (~15 min) then app (~2 min)

# 2. Start containers
./scripts/docling-compose.sh
# -> Option 1: Start CPU service

# 3. Verify health
curl http://localhost:8042/health

# 4. Test conversion
curl -X POST http://localhost:8042/convert \
  -F "file=@test.pdf" \
  -F "output_markdown=true"
```

### Full Deployment: Build, Push, Deploy to Cloud

```bash
# 1. Build locally
./scripts/docling-gpu.sh
# -> Option 1: Build BASE
# -> Option 2: Build APP

# 2. Test locally
./scripts/docling-gpu.sh
# -> Option 4-6: Run containers
# -> Option 10-12: Health checks

# 3. Login to ghcr.io (one-time)
export GHCR_USER=nshkrdotcom
export GHCR_TOKEN=ghp_xxxx
./scripts/docling-gpu.sh
# -> Option 16: Login

# 4. Push images
./scripts/docling-gpu.sh
# -> Option 19: Push BOTH images

# 5. Provision Vast.ai instance
export VAST_API_KEY=abc123
./scripts/docling-vast.sh
# -> Option 3-4: Provision instance

# 6. Verify cloud instance
./scripts/docling-vast.sh
# -> Option 8: Health check
```

---

## Key Design Principles

1. **Standardized Ports** (8040-8044)
   - Single `docling-ports.env` source of truth
   - Easy to change globally

2. **Two-Layer Docker Strategy**
   - Base image: Heavy (8 GB models), built rarely
   - App image: Light (1.5 GB), rebuilt on every code change
   - Fast push/pull from registry

3. **Cost Control**
   - Auto-shutdown idle Vast instances
   - Health checks every 5 min
   - Clear pricing per backend

4. **Production-Ready**
   - Docker health checks on all containers
   - Graceful shutdown on Vast instances
   - HTTPS via Caddy on cloud instances
