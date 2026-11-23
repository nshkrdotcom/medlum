# Medlum – Quick Start Guide

Follow the [local onboarding guide](DEVELOPMENT.md#local-onboarding) to
install the prerequisites, start native Docling with `uv`, configure PDF
upload routing, and launch Phoenix. Local development can run without Docker
or a Vast.ai account.

Phoenix serves at **http://localhost:4000**.

## 🔐 First login & doctor access

1. Visit **http://localhost:4000/users/log-in**.
2. Sign in with the seeded admin user:
   - Email: `admin@medlumai.local`
   - Password: `MedlumAdmin!reset` (change in `priv/repo/seeds.exs` or via env vars before running `mix setup`).
3. Open **http://localhost:4000/admin/invitations** and create a **Doctor** invitation.
4. Open the generated invitation link (new tab or private window), set the account password, and confirm via the emailed magic link (dev mailbox at **/dev/mailbox**).
5. Log in as that doctor user and head to **http://localhost:4000/reports**.

The `/reports` LiveView requires the doctor role or higher.

## ✅ What you’ll see on `/reports`

The UI renders a complete clinical summary experience driven by the sample dataset in `lib/medlum/medical/mock_documents.ex`:

- **Medical document sidebar** – six hardcoded documents (doctor note, cardiology consult, labs, radiology, discharge summary, infectious disease note) with color-coded badges.
- **Clinical summary report** – Chief Complaint, detailed HPI breakdowns, Medications, Exam, ROS, Labs, Imaging, Pathology, Assessment, Plan.
- **Provenance badges** – inline `|source:doc-XXX` links open the selected document modal with Summary / Cleaned / Raw tabs.

Everything you see is LiveView-powered, composable Tailwind components—the only “mock” piece is the data source module feeding the socket assigns.

## 🔐 Authentication & roles

- Password + magic-link login flows are available on `/users/log-in`.
- Invitations (doctor/admin/system administrator) are managed in `/admin/invitations`.
- `/users/settings` lets authenticated users update credentials and view sudo-mode prompts.
- Route access is enforced via `MedlumWeb.UserAuth` plugs (`require_doctor_role`, `require_admin_role`, etc.).

## 📁 Project structure (high level)

```
medlum/
├── lib/
│   ├── medlum/              # Contexts, Repo, mock medical data
│   └── medlum_web/          # Phoenix web layer (LiveViews, controllers, components)
├── assets/                    # Tailwind + esbuild sources
├── priv/
│   ├── repo/migrations        # Users, tokens, invitations migrations
│   └── static/                # Logos, background patterns, digested assets
├── config/                    # dev/test/prod configs
└── docs/                      # Regulatory + architecture references
```

Report styling lives in `lib/medlum_web/live/reports_live.ex`; the mock data is in `lib/medlum/medical/mock_documents.ex`.

## 🎯 Current state

| Capability                     | Status |
|--------------------------------|--------|
| Passwordless + password auth   | ✅     |
| Role-based routing & invitations | ✅   |
| Admin console (/admin/invitations) | ✅ |
| `/reports` UI experience       | ✅ (mock data) |
| Real ingestion / LLM pipeline  | ✅ (PDF ➜ ingestion jobs ➜ markdown) |

Upload PDFs directly in `/reports` to generate new markdown narratives; the prompts are editable at `/prompts`.

## 🔜 Next steps

1. **Document ingestion** – add upload + classification flows that replace the mock module with persisted records.
2. **LLM summarization** – call Gemini (or other HIPAA-covered models) per section, emit `text|source:doc-x` payloads.
3. **Traceable intelligence** – implement the multi-agent critic pipeline described in `docs/20251116/001_MEDLUM_claude.md`.
4. **HIPAA hardening** – follow the architecture in `docs/20251114/` for hybrid deployments, audit logging, etc.

## 🎨 Customization pointers

- Update report layout/components: `lib/medlum_web/live/reports_live.ex`.
- Adjust mock data / sections: `lib/medlum/medical/mock_documents.ex`.
- Login experience, backgrounds, logo animations: `lib/medlum_web/live/user_live/login.ex` and `priv/static/images/`.
- Global Tailwind/DaisyUI settings: `assets/css/app.css`.

## 🐛 Common issues

- **Port 4000 busy** – `lsof -ti:4000 | xargs kill -9` or set `PORT=4001 mix phx.server`.
- **Missing deps/DB** – re-run `mix setup` (includes `ecto.create`, migrations, seeds).
- **Assets not rebuilding** – `mix assets.setup && mix assets.build`.
- **Forgot admin password** – re-run `mix run priv/repo/seeds.exs` with new env vars or update via IEx.

## 📬 Need the mailbox?

When running in dev, visit **http://localhost:4000/dev/mailbox** to open magic-link emails sent by Swoosh’s local adapter.

You’re now aligned with the current codebase—full auth + admin flows running, with mock data for reporting until the ingestion/LLM pipeline lands. Happy building!
