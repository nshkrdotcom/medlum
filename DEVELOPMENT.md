# Medlum Web – Development Guide

This repo hosts the full Phoenix LiveView application for Medlum. Authentication, invitations, and role-based routing are production-ready; the `/reports` LiveView now renders from the ingestion/LLM pipeline (PDF uploads persisted in Postgres + Gemini markdown + section drafting).

## Local onboarding

Run Phoenix, PostgreSQL, and Docling on the development machine. Docling is a
separate Python service that Phoenix calls over HTTP.

### 1. Install prerequisites and set up Phoenix

- Install Git, Elixir 1.17 or newer, and a compatible Erlang/OTP release (27
  or newer recommended). Install a C compiler and Make for native Mix dependencies.
- Install PostgreSQL 14 or newer and start it. The dev configuration uses
  `postgres` / `postgres` on `localhost:5432` and creates the `medlum_dev`
  database. Match your local PostgreSQL credentials in `config/dev.exs` if needed.
- Install `uv` and put it on your `PATH`. It installs Python and manages
  Docling's isolated environment. Install `curl` and `jq` for the smoke test.
  [uv installation guide](https://docs.astral.sh/uv/getting-started/installation/)
- For GPU conversion, use Linux or WSL with an NVIDIA driver and verify
  `nvidia-smi` sees your card. On WSL, install the driver on Windows. The
  PyTorch wheels supply the CUDA runtime. [NVIDIA CUDA on WSL guide](https://docs.nvidia.com/cuda/wsl-user-guide/)
- Allow several gigabytes for PyTorch and Docling's model cache. On Debian or
  Ubuntu, install the GL and GLib runtime libraries if imports fail with
  missing `libGL.so.1` or `libglib-2.0.so.0` (typically `libgl1` and the
  distribution's GLib runtime package).

From the Medlum repository root on a fresh checkout:

```bash
mix local.hex --force
mix local.rebar --force
DOCLING_DOCKER_AUTO_MANAGE=false mix setup
```

`mix setup` fetches dependencies, creates and migrates the database, seeds the
admin account, and builds the frontend with esbuild and Tailwind. On an
existing checkout, use `mix deps.get`, `mix ecto.migrate`, and `mix assets.build`.

### 2. Start native Docling

Open a terminal from the Medlum repository root. For an NVIDIA GPU such as the
RTX 5060 Ti, use the CUDA 12.8 wheels and port 8041:

```bash
cd docling_service
uv python install 3.12
uv venv --python 3.12 .venv-gpu
uv pip install --python .venv-gpu/bin/python \
  --index https://download.pytorch.org/whl/cu128 torch torchvision
uv pip install --python .venv-gpu/bin/python -r requirements.txt
.venv-gpu/bin/python -c 'import torch; assert torch.cuda.is_available(); print(torch.cuda.get_device_name())'
OMP_NUM_THREADS=4 .venv-gpu/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8041
```

For CPU-only development on Linux, use a separate environment and port 8040:

```bash
cd docling_service
uv python install 3.12
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python \
  --index https://download.pytorch.org/whl/cpu torch torchvision
uv pip install --python .venv/bin/python -r requirements.txt
CUDA_VISIBLE_DEVICES="" OMP_NUM_THREADS=4 .venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8040
```

Keep the service running. The first PDF conversion downloads model weights.
After setup, start Uvicorn with the last command in the relevant block.

### 3. Route local uploads and start Phoenix

In a second terminal at the Medlum repository root, set the dev database's
Standard upload profile to native GPU. Run this once when choosing a backend:

```bash
DOCLING_DOCKER_AUTO_MANAGE=false mix run -e '
  alias Medlum.Docling.Settings
  {:ok, settings} = Settings.fetch_or_init()
  {:ok, _} = Settings.update_settings(%{
    active_local_backend: "native_gpu",
    native_gpu_url: "http://127.0.0.1:8041",
    v2_profile_backends: Map.put(settings.v2_profile_backends, "standard", ["local_gpu"])
  })
'
DOCLING_DOCKER_AUTO_MANAGE=false mix phx.server
```

For CPU-only development, use `"native_cpu"` for `active_local_backend`,
`native_cpu_url: "http://127.0.0.1:8040"` for the URL, and `["local_cpu"]` for the
Standard profile. The profile controls routing for new uploads. The active
backend field is also shown on the admin page.

Open http://localhost:4000/users/log-in and request a magic link for
`admin@medlumai.local`. Open the link from the
[dev mailbox](http://localhost:4000/dev/mailbox). Check backend health at
`/admin/docling` and choose **Local** when uploading a PDF on `/reports`.
Set `GEMINI_API_KEY` in the Phoenix terminal if you want to test generated report
sections. The Gemini key is optional for the Docling smoke test.

### 4. Smoke-test local conversion

From the repository root, use port 8041 for GPU or 8040 for CPU:

```bash
docling_url=http://127.0.0.1:8041
curl -fsS "$docling_url/health"
job_id=$(curl -fsS -F 'file=@docling_service/test.pdf' "$docling_url/jobs" | jq -er .job_id)
curl -fsSN "$docling_url/jobs/$job_id/stream" |
  sed -n 's/^data: //p' |
  jq -c '{type, state, device, pages_done, pages_total, progress}'
```

Expect a `page_processed` event followed by a terminal `completed` event. For
the GPU path, the running and completed events should show `cuda:0`.

## Feature snapshot

| Feature                                      | Status | Notes |
|----------------------------------------------|--------|-------|
| Password & magic-link login                  | ✅     | `/users/log-in`, `Accounts.login_user_by_magic_link/1` |
| Invitations & role assignment                | ✅     | `/admin/invitations`, roles: doctor/admin/system_admin |
| Role-based routing                           | ✅     | `MedlumWeb.UserAuth` plugs guard doctor/admin scopes |
| `/reports` LiveView UI                       | ✅     | Driven by persisted uploads + ingestion jobs |
| Real ingestion / LLM summarization           | ✅     | PDF uploads -> Gemini structured outputs |
| Multi-agent critic pipeline & attribution    | 🚧     | See `docs/20251116/001_MEDLUM_claude.md` |

## Architecture overview

```
lib/
├── medlum/                   # Contexts + data sources
│   ├── accounts/               # Users, tokens, invitations, scope
│   ├── medical/mock_documents.ex
│   └── repo.ex
└── medlum_web/               # Phoenix interface
    ├── components/             # UI components + layouts
    ├── controllers/            # Page + auth controllers
    ├── live/                   # LiveViews (user auth, admin, reports)
    ├── endpoint.ex             # Phoenix endpoint + Tidewave hook
    └── user_auth.ex            # Auth/role plugs & helpers
assets/                         # Tailwind 4 + esbuild sources
priv/
├── repo/migrations             # Users, tokens, invitations
└── static/                     # Logos, background patterns, digested assets
```

### Authentication & invitations

- `Medlum.Accounts` manages registration, invitations, password updates, session/magic-link tokens, and sudo-mode enforcement.
- `Medlum.Accounts.Scope` wraps the current user and is assigned in `MedlumWeb.UserAuth.fetch_current_scope_for_user`.
- `MedlumWeb.UserAuth` exposes plugs: `require_authenticated_user`, `require_doctor_role`, `require_admin_role`, `require_system_admin_role`.
- User-facing LiveViews: `lib/medlum_web/live/user_live/*.ex`.
- Admin invitation console: `lib/medlum_web/live/admin/invitations_live.ex`.

### Reports LiveView

`lib/medlum_web/live/reports_live.ex` now reads from the persisted ingestion tables and renders:

- Left sidebar of mock documents.
- Detailed clinical summary sections with inline provenance badges.
- Document modal with Summary / Cleaned / Raw tabs (wired via `handle_event/3`).

To prototype new sections, update the section prompt in `/prompts`, adjust the output schema (`report_section_templates.output_schema`), then add components in `ReportsLive`.

## Developer workflows

| Task | Command |
|------|---------|
| Install deps, database, and assets | `DOCLING_DOCKER_AUTO_MANAGE=false mix setup` |
| Start Phoenix with native Docling | `DOCLING_DOCKER_AUTO_MANAGE=false mix phx.server` |
| Re-seed admin | `mix run priv/repo/seeds.exs` |
| Run tests | `mix test` |
| Format code | `mix format` |
| Pre-commit gate | `mix precommit` (compile w/ warnings-as-errors, unlock unused deps, format, test) |
| Deploy assets | `mix assets.deploy` |

### Workspace helpers

- `mix medlum.purge_uploads` – Remove all persisted uploads/ingestion jobs. Useful when iterating on the `/reports` UI and you need a clean slate.

### Docling ingestion debugging

- `mix docling.queue [limit]` – List the most recent ingestion jobs with their state/progress.
- `mix docling.retry <job_id>` – Re-queue a failed job using the stored PDF and last template.
- `scripts/logs_docling.sh` – Tail the Docling service logs (defaults to `docling.service`).

### Creating doctor access in dev

1. Log in as the seeded admin.
2. Visit `/admin/invitations`.
3. Generate a Doctor invitation and open the link to register a new account.
4. Confirm via the dev mailbox magic link, then log in and visit `/reports`.

### Adjusting mock data

- Edit sample documents/report: `lib/medlum/medical/mock_documents.ex`.
- Add new report sections: extend the `Report` struct, populate data, then add UI sections in `ReportsLive`.
- Source badges follow the `"text|source:doc-001,doc-002"` pattern already parsed by `<.render_with_sources>` helpers.

## Future roadmap

Derived from `docs/`:

1. **Document ingestion pipeline**
   - File uploads (PDF, DOCX) with classification.
    - Persistence (Ecto schemas) replacing legacy mocks.
2. **LLM summarization + provenance**
   - Section-specific prompts via Gemini (or HIPAA-covered providers).
   - Emit structured outputs with evidence IDs.
3. **Traceable intelligence layer**
   - Multi-agent critic & ensemble pipeline (see `docs/20251116/001_MEDLUM_claude.md`).
   - Token-level telemetry storage + attribution graphs.
4. **Compliance & deployment hardening**
   - Follow `docs/20251114/*` for HIPAA/FDA processes, hybrid architecture, SBIR-driven validation.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Port already in use | `lsof -ti:4000 | xargs kill -9` or set `PORT=4001` |
| DB connection errors | Ensure PostgreSQL running locally; rerun `mix ecto.setup` |
| Magic link not arriving | Check `/dev/mailbox`; ensure dev routes enabled (`config :medlum, dev_routes: true`) |
| Assets not rebuilding | `mix assets.setup && mix assets.build` |
| Need fresh admin creds | Delete/reset DB or rerun `mix run priv/repo/seeds.exs` with new env vars |

## References

- `AGENTS.md` – project philosophy, design rules, LiveView conventions.
- `README.md` – deployment/dependency overview.
- `docs/20251114/*` – HIPAA + FDA strategies.
- `docs/20251116/001_MEDLUM_claude.md` – target architecture for traceable AI runtime.

Stay within the serene/clinical aesthetic described in `AGENTS.md`, keep LiveView best practices (Layouts.app, `current_scope`, `to_form/2`), and lean on the ingestion context for real data instead of ad-hoc mocks.
