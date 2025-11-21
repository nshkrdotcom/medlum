# Lumainus Web – Development Guide

This repo hosts the full Phoenix LiveView application for Lumainus. Authentication, invitations, and role-based routing are production-ready; the `/reports` LiveView now renders from the ingestion/LLM pipeline (PDF uploads persisted in Postgres + Gemini markdown + section drafting).

## Quick start

```bash
cd /home/home/p/g/n/lumainus
mix setup          # deps.get + ecto.create + ecto.migrate + seeds + assets.setup/build
mix phx.server
```

- Export your Gemini key before starting Phoenix so `/reports` can run the real LLM pipeline:

```bash
export GEMINI_API_KEY="ya29.your-google-generative-ai-key"
```

- App: **http://localhost:4000** (or `lumainus.test:4000` if you added the hosts entry from `README.md`).
- Dev mailbox: **http://localhost:4000/dev/mailbox** (magic link emails).
- LiveDashboard: **http://localhost:4000/dev/dashboard** (dev only).

The `mix setup` alias seeds a confirmed `system_administrator`:

```
Email: admin@lumainus.local
Password: LumainusAdmin!reset
```

Override via `LUMAINUS_ADMIN_*` env vars before running `mix setup`.

## Feature snapshot

| Feature                                      | Status | Notes |
|----------------------------------------------|--------|-------|
| Password & magic-link login                  | ✅     | `/users/log-in`, `Accounts.login_user_by_magic_link/1` |
| Invitations & role assignment                | ✅     | `/admin/invitations`, roles: doctor/admin/system_admin |
| Role-based routing                           | ✅     | `LumainusWeb.UserAuth` plugs guard doctor/admin scopes |
| `/reports` LiveView UI                       | ✅     | Driven by persisted uploads + ingestion jobs |
| Real ingestion / LLM summarization           | ✅     | PDF uploads -> Gemini structured outputs |
| Multi-agent critic pipeline & attribution    | 🚧     | See `docs/20251116/001_LUMAINUS_claude.md` |

## Architecture overview

```
lib/
├── lumainus/                   # Contexts + data sources
│   ├── accounts/               # Users, tokens, invitations, scope
│   ├── medical/mock_documents.ex
│   └── repo.ex
└── lumainus_web/               # Phoenix interface
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

- `Lumainus.Accounts` manages registration, invitations, password updates, session/magic-link tokens, and sudo-mode enforcement.
- `Lumainus.Accounts.Scope` wraps the current user and is assigned in `LumainusWeb.UserAuth.fetch_current_scope_for_user`.
- `LumainusWeb.UserAuth` exposes plugs: `require_authenticated_user`, `require_doctor_role`, `require_admin_role`, `require_system_admin_role`.
- User-facing LiveViews: `lib/lumainus_web/live/user_live/*.ex`.
- Admin invitation console: `lib/lumainus_web/live/admin/invitations_live.ex`.

### Reports LiveView

`lib/lumainus_web/live/reports_live.ex` now reads from the persisted ingestion tables and renders:

- Left sidebar of mock documents.
- Detailed clinical summary sections with inline provenance badges.
- Document modal with Summary / Cleaned / Raw tabs (wired via `handle_event/3`).

To prototype new sections, update the section prompt in `/prompts`, adjust the output schema (`report_section_templates.output_schema`), then add components in `ReportsLive`.

## Developer workflows

| Task | Command |
|------|---------|
| Install deps + DB + assets | `mix setup` |
| Start server | `mix phx.server` |
| Start Phoenix + Docling (dev) | `scripts/dev_stack.sh` |
| Re-seed admin | `mix run priv/repo/seeds.exs` |
| Run tests | `mix test` |
| Format code | `mix format` |
| Pre-commit gate | `mix precommit` (compile w/ warnings-as-errors, unlock unused deps, format, test) |
| Deploy assets | `mix assets.deploy` |

### Workspace helpers

- `mix lumainus.purge_uploads` – Remove all persisted uploads/ingestion jobs. Useful when iterating on the `/reports` UI and you need a clean slate.

### Docling ingestion debugging

- `mix docling.queue [limit]` – List the most recent ingestion jobs with their state/progress.
- `mix docling.retry <job_id>` – Re-queue a failed job using the stored PDF and last template.
- `scripts/logs_docling.sh` – Tail the Docling service logs (defaults to `docling.service`).

### Run Phoenix + Docling ingestion together (dev only)

The new helper script starts the PDF ingestion microservice (inside its Python virtualenv) and the Phoenix server in one go so `/reports` always has a local Docling endpoint:

```bash
scripts/dev_stack.sh
```

- Forces `MIX_ENV=dev` and exits otherwise (keeps production deploys separate).
- Launches Docling via `docling_service/run.sh` using its `.venv`, binding to `127.0.0.1:8042`.
- Runs Phoenix with `mix phx.server` in the repo root.
- Stops the Docling process automatically when you `Ctrl+C` Phoenix.

Environment knobs:

```bash
DOCLING_PORT=9050 PHX_CMD="iex -S mix phx.server" scripts/dev_stack.sh
```

Available overrides: `DOCLING_HOST`, `DOCLING_PORT`, `DOCLING_PYTHON_BIN`, and `PHX_CMD`. Use them if you need different bind addresses or want to run Phoenix via `iex`.

### Creating doctor access in dev

1. Log in as the seeded admin.
2. Visit `/admin/invitations`.
3. Generate a Doctor invitation and open the link to register a new account.
4. Confirm via the dev mailbox magic link, then log in and visit `/reports`.

### Adjusting mock data

- Edit sample documents/report: `lib/lumainus/medical/mock_documents.ex`.
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
   - Multi-agent critic & ensemble pipeline (see `docs/20251116/001_LUMAINUS_claude.md`).
   - Token-level telemetry storage + attribution graphs.
4. **Compliance & deployment hardening**
   - Follow `docs/20251114/*` for HIPAA/FDA processes, hybrid architecture, SBIR-driven validation.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Port already in use | `lsof -ti:4000 | xargs kill -9` or set `PORT=4001` |
| DB connection errors | Ensure PostgreSQL running locally; rerun `mix ecto.setup` |
| Magic link not arriving | Check `/dev/mailbox`; ensure dev routes enabled (`config :lumainus, dev_routes: true`) |
| Assets not rebuilding | `mix assets.setup && mix assets.build` |
| Need fresh admin creds | Delete/reset DB or rerun `mix run priv/repo/seeds.exs` with new env vars |

## References

- `AGENTS.md` – project philosophy, design rules, LiveView conventions.
- `README.md` – deployment/dependency overview.
- `docs/20251114/*` – HIPAA + FDA strategies.
- `docs/20251116/001_LUMAINUS_claude.md` – target architecture for traceable AI runtime.

Stay within the serene/clinical aesthetic described in `AGENTS.md`, keep LiveView best practices (Layouts.app, `current_scope`, `to_form/2`), and lean on the ingestion context for real data instead of ad-hoc mocks.
