# Docling REST Microservice

A minimal FastAPI application that exposes Docling's PDF → Markdown pipeline over HTTP for private use inside Lumainus.

## Contents

- `app/main.py` – FastAPI app + Docling integration
- `requirements.txt` – Python deps (FastAPI, uvicorn, Docling)
- `run.sh` – Bootstrap helper that creates `.venv`, installs deps, and launches the service

## Prerequisites

- Python 3.10–3.12 available on the host (Docling upstream requirement)
- Enough disk/RAM for Docling's models (~1 GB disk cache, ~3 GB RAM peak during conversions)

## Quick start

```bash
cd docling_service
./run.sh               # creates .venv, installs deps, runs uvicorn on port 8042
```

Environment variables:

- `PYTHON_BIN` – Python interpreter to use (`python3` by default)
- `HOST` / `PORT` – bind address (defaults: `0.0.0.0:8042`)
- `PIP_EXTRA_INDEX_URL` – defaults to `https://download.pytorch.org/whl/cpu` (set explicitly to override)

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
        {"label": "section_header", "text": "Summary", "bbox": [ ... ]}
      ]
    }
  ]
}
```

Set `output_markdown=false` if you only want per-page structures without the merged Markdown field.

## Production notes

- First request downloads Docling's Heron layout + OCR weights into `~/.cache/docling`.
- Keep the service private (no auth built in). Run behind your Phoenix app or a reverse proxy with ACLs.
- For systemd usage, point the unit to `ExecStart=/path/to/docling_service/run.sh` and set `WorkingDirectory` accordingly.

## GPU dev quickstart (Vast.ai)

You can spin up a GPU Docling service for testing with a single script once you have a Vast.ai instance:

1. Rent a GPU on Vast.ai (public IP + open port), note the `user@host:port`.
2. Run from your laptop: `scripts/bootstrap_vast_gpu.sh user@host:port main`
   - Env overrides: `PORT` (default 8042), `REMOTE_ROOT` (default `/opt/lumainus`), `REPO_URL` (defaults to your git origin), `PIP_EXTRA_INDEX_URL` (defaults to CUDA 12.1 wheels).
   - The script installs deps, clones this repo, installs GPU wheels, and backgrounds `docling_service` on the remote host. Logs at `/opt/lumainus/docling_service.log`.
3. Point Lumainus admin Docling endpoint to `http://<host>:8042`.

To restart, rerun the script; to view logs: `ssh user@host "tail -f /opt/lumainus/docling_service.log"`.

### Panic button: destroy all Vast usage

If you need to instantly stop billing on Vast, run:
```
VAST_API_KEY=... ./scripts/vast_nuke_all.sh
```
This destroys all instances and deletes unattached volumes in your account. Verify usage drops to $0/hr on the Vast dashboard.

## Integration tips

- Phoenix can call the service via Req or Finch after storing uploads to disk/S3.
- Persist the returned `metadata`/`pages` to back the `/reports` provenance UI.
- If you only want Markdown, drop the `pages` array before storing to save space.
