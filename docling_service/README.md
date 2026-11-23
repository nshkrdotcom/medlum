# Docling REST Microservice

A minimal FastAPI application that exposes Docling's PDF → Markdown pipeline over HTTP for private use inside Medlum.

## Contents

- `app/main.py` – FastAPI app + Docling integration
- `requirements.txt` – Python deps (FastAPI, uvicorn, Docling)
- `run.sh` – Bootstrap helper that creates `.venv`, installs deps, and launches the service
- `Dockerfile.gpu` – GPU-enabled Docker image with pre-downloaded models
- `build-gpu-image.sh` – Build script for the Docker image
- `DEPLOYMENT.md` – Complete deployment guide for Vast.ai
- `../scripts/docling-gpu.sh` – Interactive management script for Docker operations

## Local development

Follow [Medlum's local onboarding guide](../DEVELOPMENT.md#local-onboarding)
to install `uv`, start native Docling on CPU or NVIDIA GPU, and connect Phoenix.
The service installs official Docling 2.151.1 from `requirements.txt` and
has no dependency on the former fork.

Environment variables:

- `PYTHON_BIN` – Python interpreter to use (`python3` by default)
- `HOST` / `PORT` – bind address for `run.sh`; the local guide binds to loopback on 8040 (CPU) or 8041 (GPU)
- `DOC_CONVERTER_WORKERS` – independent converters (default 1 per service)
- `DOCLING_TORCH_INDEX` – defaults to `https://download.pytorch.org/whl/cpu` (set explicitly to override)

Once running, hit:

- `GET /health` – service heartbeat
- `POST /convert` – convert a PDF (see below)

## `/convert` endpoint

`POST /convert` accepts either a file upload or a `source_url` query parameter.

### Upload example

```bash
curl -X POST "http://localhost:8042/convert" \
  -F "file=@/path/to/report.pdf" \
  -F "output_markdown=true"
```

### Remote URL example

```bash
curl -X POST "http://localhost:8042/convert?source_url=https://example.com/foo.pdf"
```

### Response shape

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
      "cells": [
        {"text": "Patient", "bbox": [0.1, 0.8, 0.5, 0.9], "ocr": false, "ocr_confidence": null}
      ],
      "segments": [
        {"label": "section_header", "text": "Summary", "bbox": [0.1, 0.2, 0.5, 0.3]}
      ]
    }
  ]
}
```

Set `output_markdown=false` if you only want per-page structures without the merged Markdown field.

## Conversion jobs

- `POST /jobs` enqueues a PDF and returns its job ID.
- `GET /jobs/{id}/stream` streams Docling page progress over SSE and closes after the terminal event.
- `DELETE /jobs/{id}` cancels a queued or running job. An active Docling model call may continue in the worker, and its result is discarded.

## Production notes

- The first native conversion downloads and caches model weights. Docker builds download the weights into the image.
- Keep the service private (no auth built in). Run behind your Phoenix app or a reverse proxy with ACLs.
- For systemd usage, point the unit to `ExecStart=/path/to/docling_service/run.sh` and set `WorkingDirectory` accordingly.

## GPU Deployment (Docker)

The recommended approach for GPU deployment is the pre-built Docker image with all models baked in. This provides fast (~3-5 min) instance boot times on Vast.ai.

### Management Script

Use the interactive management script for all Docker operations:

```bash
./scripts/docling-gpu.sh
```

**Menu options:**
```
BUILD & TEST
  1) Build Docker image
  2) Run locally (CPU mode)
  3) Run locally (GPU mode)
  4) Stop running container

HEALTH CHECKS
  5) Test health endpoint
  6) Test PDF conversion
  7) View container logs

REGISTRY
  8) Login to ghcr.io
  9) Push image to ghcr.io
 10) Check ghcr.io login status

CLEANUP
 11) Remove local image
 12) Prune Docker system
```

Or use command-line shortcuts:
```bash
./scripts/docling-gpu.sh build    # Build image
./scripts/docling-gpu.sh login    # Login to ghcr.io
./scripts/docling-gpu.sh push     # Push to registry
./scripts/docling-gpu.sh run      # Run container (CPU)
./scripts/docling-gpu.sh health   # Test health endpoint
```

### Quick Start

```bash
# 1. Build the image (~10 min first time)
./scripts/docling-gpu.sh build

# 2. Test locally
./scripts/docling-gpu.sh run
./scripts/docling-gpu.sh health

# 3. Login and push to private registry
export GHCR_USER=nshkrdotcom
export GHCR_TOKEN=ghp_your_token_here
./scripts/docling-gpu.sh login
./scripts/docling-gpu.sh push
```

### Private Registry Setup

The image is hosted on GitHub Container Registry (ghcr.io) as a **private** package:

1. Create a GitHub PAT at https://github.com/settings/tokens with `write:packages` and `read:packages` scopes
2. Set environment variables:
   ```bash
   export GHCR_USER=nshkrdotcom
   export GHCR_TOKEN=ghp_xxxx...
   ```
3. Login and push using the management script (options 8 & 9)

For Vast.ai to pull private images, the Medlum admin UI automatically includes `docker_login` credentials when provisioning. Configure in your environment:
```bash
export VAST_API_KEY=your_vast_key
export GHCR_TOKEN=ghp_xxxx  # Same token, needs read:packages
```

See [DEPLOYMENT.md](./DEPLOYMENT.md) for the complete deployment guide.

### Vast.ai via Admin UI

1. Go to `/admin/vast_ai` in the Medlum web interface
2. Search for GPU offers (RTX 3090 recommended)
3. Select "Docling GPU (pre-built)" from the image dropdown
4. Click "Provision" on your chosen offer
5. Wait 3-5 minutes for the instance to boot
6. Use "Test Health" button to verify the service is ready

### Manual Docker Commands

```bash
# Build from the Medlum repository root
./scripts/docling-gpu.sh build-all

# Run (CPU)
docker run -p 8042:8042 ghcr.io/nshkrdotcom/medlum-docling-gpu:2.151.1

# Run (GPU)
docker run --gpus all -p 8042:8042 ghcr.io/nshkrdotcom/medlum-docling-gpu:2.151.1

# Test
curl http://localhost:8042/health
curl -X POST http://localhost:8042/convert -F "file=@test.pdf"
```

## Native GPU Deployment (Vast.ai)

For manual GPU setup without Docker, you can use the bootstrap script:

Run `./scripts/docling-vast.sh` from the Medlum checkout and choose the SSH
deployment option, or call `./scripts/bootstrap_vast_gpu.sh user@host:port main`.
The bootstrap checks out Medlum on the remote host and starts Docling with
CUDA 12.8 PyTorch wheels. It installs the official Docling release from
`requirements.txt`. Set `REPO_URL` if the remote host uses a different clone URL.

### Panic button: destroy all Vast usage

If you need to instantly stop billing on Vast, run:
```
VAST_API_KEY=... ../docling/scripts/vast_nuke_all.sh
```
This destroys all instances and deletes unattached volumes in your account. Verify usage drops to $0/hr on the Vast dashboard.

## Integration tips

- Phoenix can call the service via Req or Finch after storing uploads to disk/S3.
- Persist the returned `metadata`/`pages` to back the `/reports` provenance UI.
- If you only want Markdown, drop the `pages` array before storing to save space.
