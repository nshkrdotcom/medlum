<p align="center">
  <img src="assets/medlum.svg" width="200" height="200" alt="Medlum logo" />
</p>

<h1 align="center">Medlum</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/medlum"><img alt="GitHub: medlum" src="https://img.shields.io/badge/GitHub-medlum-081c26?logo=github" /></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-14b8a6.svg" /></a>
</p>

Advanced Medical Reporting & Analytics Platform built with Phoenix LiveView.

## Features

- **Passwordless Authentication** - Secure magic link login system
- **Role-Based Access Control** - Four tier permission system:
  - `guest` - Basic read access
  - `doctor` - Medical professional access
  - `admin` - Administrative privileges
  - `system_administrator` - Full system control
- **Invitation System** - Secure user registration via admin-generated invitation links
- **Phoenix LiveView** - Real-time, server-rendered UI
- **Tailwind CSS + DaisyUI** - Modern, responsive design
- **Tidewave Integration** - AI-powered development assistance
- **Clinical Summary UI** - `/reports` LiveView with provenance badges backed by the persisted ingestion pipeline (Gemini structured outputs + PDF uploads)
- **Docling PDF ingestion** - Local CPU or GPU processing with streamed progress, layout provenance, and an optional cloud backend
- **Traceable LLM Runs** - Latest section runs preload only shallow LLM invocation metadata (id/provider/model/status/usage) to avoid pulling large prompt/response blobs in `/reports`

## Local Development

Start with the [local onboarding guide](DEVELOPMENT.md#local-onboarding).
It covers PostgreSQL, Elixir, and installing official Docling with `uv`.
Run Docling directly on the host for local development. Docker and Vast.ai
are optional deployment paths.

Phoenix runs at http://localhost:4000. Set `GEMINI_API_KEY` before starting it
to generate report sections with Gemini. Docling PDF conversion runs locally.

## First Login

1. Visit http://localhost:4000/users/log-in
2. Enter email: `admin@medlumai.local`
3. Check the dev mailbox: http://localhost:4000/dev/mailbox
4. Click the magic link in the email
5. You'll be logged in as system administrator

## Admin Panel

After logging in as admin, access the admin panel:

**Invitation Management:** http://localhost:4000/admin/invitations

From here you can:
- Create invitation links for new users
- Set roles for invitations (doctor, admin, etc.)
- View pending invitations
- Revoke unused invitations

**Docling Configuration:** http://localhost:4000/admin/docling

- Admin-only panel for backend health, URLs, and timeouts.
- The [local setup](DEVELOPMENT.md#3-route-local-uploads-and-start-phoenix) configures the Standard upload profile for native Docling.

## User Roles & Permissions

### Guest
- Default role for new users
- Read-only access to basic features
- Cannot create or modify data

### Doctor
- Access to medical reporting features
- Can create and edit reports
- Patient data access

### Admin
- User management
- Create invitations
- Configure system settings
- View all reports

### System Administrator
- Full system access
- Database management
- Security configuration
- Manage other administrators

## Development

### Running Tests

```bash
mix test
```

CI note: the test repo sets `ownership_timeout: 300_000` and `migration_lock: nil` to keep migrations from timing out on shared runners.

### Running with IEx

```bash
iex -S mix phx.server
```

### Docling Backend Architecture

Medlum supports **5 Docling backends** organized into two user-facing modes:

#### Port Assignments (Standardized)

| Port | Backend | Type | Description |
|------|---------|------|-------------|
| **8040** | `native_cpu` | Local | Host Python/uvicorn, CPU only |
| **8041** | `native_gpu` | Local | Host Python/uvicorn, CUDA GPU |
| **8042** | `docker_cpu` | Local | Docker container, CPU mode |
| **8043** | `docker_gpu` | Local | Docker container, GPU mode |
| **8044** | `vast_ai` | Cloud | Vast.ai remote GPU ($$$) |

#### User-Facing Modes

- **Local** uses the Standard upload profile. Set it to native CPU or GPU for a local checkout.
- **Cloud** is the optional paid Vast.ai path.

#### Configuration

```elixir
# config/config.exs
config :medlum, :docling,
  default_mode: :local,
  active_local_backend: :docker_cpu,
  native_cpu_url: "http://127.0.0.1:8040",
  native_gpu_url: "http://127.0.0.1:8041",
  docker_cpu_url: "http://127.0.0.1:8042",
  docker_gpu_url: "http://127.0.0.1:8043",
  cloud_url: System.get_env("DOCLING_CLOUD_URL"),
  timeout_ms: 1_200_000,
  poll_interval_ms: 250,
  progress_min_interval_ms: 50
```

Environment variables:
- `DOCLING_CLOUD_URL` - Cloud/Vast.ai endpoint (required for Cloud mode)

#### Running Docling Backends

For local development, follow the [native setup](DEVELOPMENT.md#2-start-native-docling).
For container builds and deployment, see the [Docker guide](docling_service/DEPLOYMENT.md).

#### Script Reference

| Script | Description |
|--------|-------------|
| `scripts/docling-ports.env` | Central port definitions (source in other scripts) |
| `scripts/docling-gpu.sh` | Docker image management (build, run, push, health) |
| `scripts/docling-compose.sh` | Docker Compose management (start, stop, logs) |
| `scripts/setup_docling_service.sh` | Native Python setup (no Docker) |

#### Admin Panel

**URL:** http://localhost:4000/admin/docling

From here you can:
- Set default mode for new users (Local/Cloud)
- Choose active local backend (native_cpu, native_gpu, docker_cpu, docker_gpu)
- Configure URLs for all 5 backends
- View health status for each backend
- Adjust timing settings (timeout, poll interval, progress debounce)

#### Migrations

```bash
mix ecto.migrate
```

This adds the expanded backend fields to `docling_settings`.

#### Operational Notes

- Per-user preference (Local/Cloud) stored on `users.docling_backend`
- Each upload card shows a badge indicating which backend processed it
- Health-aware fallback: if Cloud is unhealthy, it's disabled in `/reports`
- Tests use Bypass mocks; no external Docling needed
- URL safety: must use `https://` unless localhost/127.0.0.1
- Progress broadcasts emit immediately on page movement, debounced otherwise
- Debug logging: set `config :medlum, :docling, debug_progress_log: true`

### Database Commands

```bash
# Create database
mix ecto.create

# Run migrations
mix ecto.migrate

# Reset database
mix ecto.reset

# Rollback migration
mix ecto.rollback
```

### Asset Compilation

```bash
# Build assets once
mix assets.build

# Deploy assets (minified)
mix assets.deploy
```

### Code Quality

```bash
# Format code
mix format

# Run precommit checks
mix precommit
```

## Tidewave Integration

Tidewave is an AI coding agent for full-stack development.

### Installing Tidewave CLI

```bash
./scripts/tidewave_server_start.sh
```

This will:
1. Check if Tidewave CLI is installed
2. Download and install it to `bin/` if needed
3. Start the Tidewave server on port 9832

### Accessing Tidewave

- **From browser:** http://localhost:9832
- **Connect to app:** http://localhost:4000

The Tidewave integration allows AI agents to:
- Read and modify code
- Execute shell commands
- Run tests
- Access LiveView components
- Manage database migrations

## Configuration

### Environment Variables

```bash
# Database
DATABASE_URL=ecto://postgres:postgres@localhost/medlum_dev

# Server
PORT=4000
SECRET_KEY_BASE=<generated-secret>

# Email (development)
# Uses local mailbox at /dev/mailbox

# LLM
GEMINI_API_KEY=<your-google-generative-ai-key>
```

### Development Domain

To use `medlum.test` instead of `localhost`:

1. Add to Windows hosts file (`C:\Windows\System32\drivers\etc\hosts`):
   ```
   172.24.75.206 medlum.test
   ```

2. Already configured in `config/dev.exs`:
   ```elixir
   url: [host: "medlum.test", port: 4000]
   ```

3. Access at: http://medlum.test:4000

## Production Deployment

See [Phoenix deployment guides](https://hexdocs.pm/phoenix/deployment.html).

Key steps:
1. Set production environment variables
2. Build assets: `mix assets.deploy`
3. Run migrations: `mix ecto.migrate`
4. Start server: `mix phx.server`

## Architecture

```
medlum/
├── assets/          # Frontend assets (JS, CSS)
├── config/          # Application configuration
├── lib/
│   ├── medlum/          # Core domain logic
│   │   ├── accounts/      # User authentication & authorization
│   │   └── repo.ex        # Database repository
│   └── medlum_web/      # Web interface
│       ├── components/    # Reusable LiveView components
│       ├── controllers/   # HTTP controllers
│       ├── live/          # LiveView modules
│       └── router.ex      # Route definitions
├── priv/
│   ├── repo/
│   │   ├── migrations/    # Database migrations
│   │   └── seeds.exs      # Seed data
│   └── static/            # Compiled static assets
├── scripts/         # Development & operations scripts
│   ├── docling-ports.env         # Docling port definitions
│   ├── docling-gpu.sh            # Docker image management
│   ├── docling-compose.sh        # Docker Compose management
│   ├── setup_docling_service.sh  # Native Python setup
│   ├── tidewave_server_install.sh
│   └── tidewave_server_start.sh
├── docker-compose.yml  # Docling backend services
└── test/            # Test files
```

## Tech Stack

- **Backend:** Elixir, Phoenix Framework 1.8
- **Frontend:** Phoenix LiveView 1.1, Alpine.js
- **Database:** PostgreSQL, Ecto
- **CSS:** Tailwind CSS 4, DaisyUI 5
- **Build:** esbuild, Tailwind CLI
- **Server:** Bandit HTTP server
- **Auth:** Phoenix.Token (passwordless magic links)

## Common Tasks

### Creating Database Migrations

```bash
mix ecto.gen.migration create_table_name
```

### Adding a New LiveView Page

```bash
mix phx.gen.live Context Schema table_name field:type
```

### Creating New User Roles

Edit `lib/medlum/accounts/user.ex` to add new roles to the enum.

### Sending Invitation Email

Invitations are created through the admin panel. The system automatically:
1. Generates a secure token
2. Creates invitation record in database
3. Provides invitation link for admin to share

## Troubleshooting

### `/reports` page is slow
- Confirm you are not preloading `llm_invocations.prompt_text`/`response_text`/`response_object` in list/latest runs; keep the shallow preload used in `Reports.latest_section_runs_map/2`.
- The main cost previously was loading a ~48MB prompt_text blob for 13 latest runs; keep heavy fields out of `/reports` queries.

### Database Connection Issues

```bash
# Check PostgreSQL is running
psql -U postgres -l

# Reset database
mix ecto.reset
```

### Asset Compilation Errors

```bash
# Clear compiled assets
rm -rf priv/static/assets

# Rebuild
mix assets.deploy
```

### Port Already in Use

```bash
# Kill process on port 4000
lsof -ti:4000 | xargs kill -9
```

## Learn More

- **Phoenix Framework:** https://www.phoenixframework.org/
- **Phoenix LiveView:** https://hexdocs.pm/phoenix_live_view
- **Ecto:** https://hexdocs.pm/ecto
- **Tailwind CSS:** https://tailwindcss.com
- **DaisyUI:** https://daisyui.com
- **Tidewave:** https://tidewave.ai

## License

MIT License — see [LICENSE](LICENSE) for details.
