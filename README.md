# Lumainus

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

## Prerequisites

- Elixir ~> 1.15
- Erlang/OTP 26+
- PostgreSQL 14+
- Node.js 18+ (for asset compilation)

## Installation & Setup

### 1. Install Dependencies

```bash
mix setup
```

This will:
- Install Elixir dependencies
- Install Node.js dependencies
- Create the database
- Run migrations
- Compile assets

### 2. Create Initial Admin Account

```bash
mix run priv/repo/seeds.exs
```

This creates a system administrator account with:
- **Email:** `admin@lumainus.local`
- **Role:** `system_administrator`

### 3. Start the Server

```bash
mix phx.server
```

> Set `GEMINI_API_KEY` in your environment before starting the server so report sections can call Gemini.

Server will be available at:
- **Main app:** http://localhost:4000
- **Dev mailbox:** http://localhost:4000/dev/mailbox

## First Login

1. Visit http://localhost:4000/users/log-in
2. Enter email: `admin@lumainus.local`
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

### Running with IEx

```bash
iex -S mix phx.server
```

### Docling Backends

- **Standard (local CPU)** – default, uses `http://127.0.0.1:8042`
- **Fast (GPU)** – set `DOCLING_REMOTE_URL=http://<gpu-host>:8042` to expose the remote Docling service. Users can toggle Fast vs Standard in `/reports`; if the GPU endpoint is unhealthy, the app will fall back to Standard automatically.

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
DATABASE_URL=ecto://postgres:postgres@localhost/lumainus_dev

# Server
PORT=4000
SECRET_KEY_BASE=<generated-secret>

# Email (development)
# Uses local mailbox at /dev/mailbox

# LLM
GEMINI_API_KEY=<your-google-generative-ai-key>
```

### Development Domain

To use `lumainus.test` instead of `localhost`:

1. Add to Windows hosts file (`C:\Windows\System32\drivers\etc\hosts`):
   ```
   172.24.75.206 lumainus.test
   ```

2. Already configured in `config/dev.exs`:
   ```elixir
   url: [host: "lumainus.test", port: 4000]
   ```

3. Access at: http://lumainus.test:4000

## Production Deployment

See [Phoenix deployment guides](https://hexdocs.pm/phoenix/deployment.html).

Key steps:
1. Set production environment variables
2. Build assets: `mix assets.deploy`
3. Run migrations: `mix ecto.migrate`
4. Start server: `mix phx.server`

## Architecture

```
lumainus/
├── assets/          # Frontend assets (JS, CSS)
├── config/          # Application configuration
├── lib/
│   ├── lumainus/          # Core domain logic
│   │   ├── accounts/      # User authentication & authorization
│   │   └── repo.ex        # Database repository
│   └── lumainus_web/      # Web interface
│       ├── components/    # Reusable LiveView components
│       ├── controllers/   # HTTP controllers
│       ├── live/          # LiveView modules
│       └── router.ex      # Route definitions
├── priv/
│   ├── repo/
│   │   ├── migrations/    # Database migrations
│   │   └── seeds.exs      # Seed data
│   └── static/            # Compiled static assets
├── scripts/         # Development scripts
│   ├── tidewave_server_install.sh
│   └── tidewave_server_start.sh
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

Edit `lib/lumainus/accounts/user.ex` to add new roles to the enum.

### Sending Invitation Email

Invitations are created through the admin panel. The system automatically:
1. Generates a secure token
2. Creates invitation record in database
3. Provides invitation link for admin to share

## Troubleshooting

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

Proprietary - All Rights Reserved
