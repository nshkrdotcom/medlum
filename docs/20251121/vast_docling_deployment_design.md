# Vast.ai–Backed Docling Deployment Design (with Local + Nginx Sidecar)

**Date:** 2025-11-22  
**Author:** AI Agents @ Lumainus  
**Scope:** End-to-end design for running our **Docling fork** in three modes: (a) local CPU (default dev), (b) local GPU (future dev), (c) Vast.ai GPU with public HTTP guarded by an Nginx sidecar (mTLS/basic token capable). No SSH tunnels; single HTTP base URL consumed by Elixir via `DOCLING_BASE_URL`.

---

## Goals & Non-Goals

- **Goals**
  - One Docker image for our Docling fork, usable locally and on Vast.ai (GPU).
  - Consistent public interface: `http(s)://<host>:8042` → Nginx sidecar → Docling FastAPI app.
  - Secure exposure on Vast.ai: allowlist + optional auth (token header) + mTLS-ready.
  - Simple operational commands (compose for local, Python CLI for Vast) with clear docs.
  - Keep Elixir integration unchanged apart from `DOCLING_BASE_URL`.
- **Non-Goals**
  - CI/CD automation (manual build/push is fine for now).
  - Autoscaling or multi-tenant routing—single instance at a time.
  - Changing ingestion semantics (queue/backoff remain as shipped).

---

## High-Level Architecture

```
            ┌─────────────────────────────┐
            │  Lumainus (Elixir)          │
            │  DOCLING_BASE_URL=...       │
            └──────────────┬──────────────┘
                           │
                ┌──────────▼──────────┐
                │   Nginx Sidecar     │ 8042
                │ - mTLS (optional)   │
                │ - Header token auth │
                │ - Access logs off   │
                └──────────┬──────────┘
                           │ proxy_pass http://docling:8042
                ┌──────────▼──────────┐
                │  Docling Fork       │
                │  (FastAPI + Uvicorn)│
                └──────────┬──────────┘
                           │
                ┌──────────▼──────────┐
                │  GPU (Vast.ai) or   │
                │  CPU (local)        │
                └─────────────────────┘
```

- **Ports:** external 8042 → Nginx 8042 → Docling 8042 (loopback).  
- **Security:** IP allowlist at Vast if available; otherwise Nginx enforces token or mTLS.  
- **Config flow:** `DOCLING_BASE_URL` points at Nginx; Docling sees original headers via `proxy_set_header`.

---

## Deployment Modes

### 1) Local CPU (default dev)
- Compose file `docker-compose.docling.yml`.
- Services: `docling` (fork), `nginx` sidecar.
- Base URL: `http://127.0.0.1:8042`.
- Queue mode: tests keep `:inline`; dev uses `:http_queue`.

### 2) Local GPU (future dev)
- Overlay compose `docker-compose.gpu.yml` adding `deploy.resources.reservations.devices` or `--gpus all`.
- Same base URL and sidecar.

### 3) Vast.ai GPU
- Image pushed to registry (e.g., `your-registry/docling-fork:latest`).
- Instance launched via Python CLI (Vast API). Entrypoint mode; no SSH.
- Nginx listens on 8042; Docling binds 0.0.0.0:8042 internally.
- Public URL: `http://<vast-public-ip>:8042` (or HTTPS if you terminate TLS at Nginx).

---

## Docker Image Strategy

- **Single multi-purpose image** built from `docling_service/`:
  - Uses our **fork**: copy `docling/` into image and `pip install -e /tmp/docling`.
  - Default env:
    - `HOST=0.0.0.0`
    - `PORT=8042`
    - `CONVERSION_TIMEOUT_SECONDS=1200`
    - `DOC_CONVERTER_WORKERS=8`
    - Access logs disabled (already in run.sh).
- Tag once; reuse for CPU and GPU (GPU handled by host runtime and drivers).

---

## Sidecar: Nginx

- Responsibilities:
  - Reverse proxy to `docling:8042`.
  - Optional **Basic token** auth: require header `X-Docling-Token: <secret>`.
  - Optional **mTLS**: if certs mounted, require client certificate.
  - Access logs off by default; error logs warn-level.
- Config fragments:
  ```nginx
  server {
    listen 8042;
    access_log off;
    error_log /dev/stderr warn;

    # Optional token auth
    if ($http_x_docling_token != $DOC_AUTH_TOKEN) { return 401; }

    # Optional mTLS
    # ssl_client_certificate /etc/nginx/certs/ca.crt;
    # ssl_verify_client on;

    location / {
      proxy_pass http://docling:8042;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_read_timeout 1200s;
    }
  }
  ```

---

## Configuration Matrix (Elixir)

| Env  | `DOCLING_BASE_URL`                  | Queue mode     | Notes                               |
|------|-------------------------------------|----------------|-------------------------------------|
| test | `http://127.0.0.1:8042` (unused)    | `:inline`      | Bypass HTTP; current behavior kept. |
| dev  | `http://127.0.0.1:8042` (compose)   | `:http_queue`  | Uses local Docker Docling+Nginx.    |
| prod | `http://<vast-ip>:8042`             | `:http_queue`  | Sidecar-protected public endpoint.  |

- `config/config.exs`: default base_url to localhost.
- `config/runtime.exs`: require `DOCLING_BASE_URL` in prod.
- Health checks: `IngestionHealthChecker`/`Docling.health/0` hit the Nginx URL.

---

## Vast.ai Provisioning Design

- **Python CLI** in `docling_service/`:
  - `vast_client.py`: thin REST wrapper (search offers, create instance with image + onstart, get/destroy).
  - `vast_manager.py`: higher-level logic:
    - find RTX 3090 offers (verified, rentable, inet_up >= 100 Mbps, disk >= 25 GB).
    - create instance with image + env + entrypoint (no SSH).
    - poll until instance `running`, then poll `/health` via public IP:8042.
    - print `DOCLING_BASE_URL=http://<ip>:8042`.
  - `manage_vast.py`:
    - `provision` → create + wait + print endpoint
    - `list` → show instances/status
    - `endpoint <id>` → print URL
    - `destroy <id>` → tear down
- **Security**:
  - Prefer Vast firewall / ACL to allowlist your office/VPN IPs.
  - If ACL unavailable, require `X-Docling-Token` via Nginx. Generate random token per instance; emit it from CLI.
  - TLS optional: mount certs into Nginx container; otherwise, use IP allowlist + token.

---

## Local Developer Workflows

**CPU default**
```bash
docker compose -f docker-compose.docling.yml up -d
export DOCLING_BASE_URL=http://127.0.0.1:8042
mix phx.server
```

**GPU (future, on CUDA host)**
```bash
docker compose -f docker-compose.docling.yml -f docker-compose.gpu.yml up -d
export DOCLING_BASE_URL=http://127.0.0.1:8042
mix phx.server
```

**Stop**
```bash
docker compose -f docker-compose.docling.yml down
```

---

## Vast Workflow (Dev/Prod)

```bash
cd docling_service
export VAST_API_KEY=...
python manage_vast.py provision
# Outputs: DOCLING_BASE_URL=http://<ip>:8042 and optionally DOC_AUTH_TOKEN

export DOCLING_BASE_URL=http://<ip>:8042
export DOCLING_AUTH_TOKEN=<token>   # if enabled; wire into Docling client headers
mix phx.server   # or deploy/restart service
```

**Teardown**
```bash
python manage_vast.py destroy <instance_id>
```

---

## Security Posture (HIPAA-aware)

- **Network:** Use Vast ACL to restrict source IPs. If not possible, require token or mTLS at Nginx.
- **Transport:** TLS optional but recommended if traffic ever leaves a trusted network; sidecar can terminate TLS.
- **Logging:** Keep access logs off; ensure Docling app logs do not include PHI. Uvicorn access logs already disabled.
- **Secrets:** Do not bake tokens/API keys into images; pass via env. Rotate `DOC_AUTH_TOKEN` per instance.
- **Data at rest:** Docling container should not persist PHI; process in-memory and return results; rely on upstream app for storage.

---

## Observability & Health

- Health endpoint: `/health` via Nginx proxy; used by `IngestionHealthChecker`.
- Timeouts: keep 1200s; Nginx `proxy_read_timeout 1200s`.
- Metrics/logs: optional; can add Req telemetry in Elixir side; keep Docling minimal.

---

## Artifacts to Add (when implementing)

- `docling_service/Dockerfile` (production) with fork installation.
- `docling_service/docker-compose.docling.yml` (CPU) and `docker-compose.gpu.yml` (override).
- `docling_service/nginx.conf` (token + mTLS ready).
- `docling_service/vast_client.py`, `vast_manager.py`, `manage_vast.py`.
- `docs/vast_setup.md` (how-to), `docs/vast_troubleshooting.md`.
- Makefile targets: `docling-up`, `docling-down`, `docling-build`, `docling-push`, `vast-provision`, `vast-destroy`.

---

## Future Enhancements

- Add HTTPS termination with Let’s Encrypt (DNS-01) in the sidecar.
- Budget guardrails: small cron/CLI to destroy idle Vast instances after N minutes of no jobs.
- Multi-instance sharding with a simple selector based on load (not needed now).
- CI build/push of Docling image to a private registry.

---

## Risks & Mitigations

- **Open port exposure:** Mitigate with IP allowlist or token/mTLS; default token on Vast path.
- **GPU availability:** Fallback to CPU compose; CLI should fail fast if no offers.
- **Config drift:** Single `DOCLING_BASE_URL` contract; no code branches by mode.
- **PHI in transit:** Prefer TLS + allowlist; avoid public Wi‑Fi without VPN.

---

## Summary

- One image, three modes (CPU local, GPU local, GPU Vast).
- Consistent base URL via Nginx sidecar.
- Security knobs: IP allowlist, token header, optional mTLS, logs minimized.
- Operational simplicity: compose locally; Python CLI for Vast. Elixir only needs `DOCLING_BASE_URL` (and optional `DOC_AUTH_TOKEN` header if enabled).
