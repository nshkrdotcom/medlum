# AI Agents Guide - Lumainus Project

**Last Updated:** November 29, 2025 (Reports latest-run preload optimization, test migration timeout fix)
**Project:** Lumainus - Traceable AI Intelligence Platform
**Tech Stack:** Elixir, Phoenix 1.8, LiveView, Tailwind 4, DaisyUI 5

---

## Project Overview

Lumainus is a **self-aware LLM runtime** and **advanced medical reporting platform** built with Phoenix LiveView. The core mission is providing **fully traceable, auditable AI intelligence** for healthcare applications.

**Brand Tagline:**
*"Every token has a traceable decision path. Every claim has attributable evidence. Every response has measurable confidence."*

### Core Domains
- 🏥 **Healthcare/Medical AI** - HIPAA compliant, FDA considerations
- 🔍 **Traceable Intelligence** - Full transparency in AI decision-making
- 📊 **Multi-Agent Verification** - Ensemble voting, critic evaluation
- 📝 **Evidence Attribution** - Every claim links to sources
- 🔒 **Secure Authentication** - Passwordless magic links, role-based access

---

## Project Structure

```
lumainus/
├── lib/
│   ├── lumainus/              # Core business logic
│   │   ├── accounts/          # User auth, roles, invitations
│   │   │   ├── user.ex        # User schema (guest, doctor, admin, system_administrator)
│   │   │   └── invitation.ex  # Invitation system
│   │   └── repo.ex            # Database repository
│   │
│   └── lumainus_web/          # Web interface (Phoenix)
│       ├── components/        # Reusable components
│       │   └── layouts/       # Layout templates
│       │       ├── root.html.heex      # HTML shell (favicon, meta tags)
│       │       └── layouts.ex          # Layout components
│       │
│       ├── controllers/       # HTTP controllers
│       │   └── page_html/     # Homepage templates
│       │       └── home.html.heex      # Main landing page
│       │
│       ├── live/              # LiveView modules
│       │   └── user_live/     # User authentication LiveViews
│       │       ├── login.ex            # Login page (passwordless + password)
│       │       ├── registration.ex     # User registration
│       │       └── settings.ex         # User settings
│       │
│       ├── router.ex          # Route definitions
│       └── endpoint.ex        # Phoenix endpoint
│
├── assets/                    # Frontend assets
│   ├── css/
│   │   └── app.css            # Tailwind 4 entry point
│   ├── js/
│   │   └── app.js             # JavaScript entry point
│   └── vendor/                # Third-party assets
│
├── priv/
│   ├── repo/
│   │   ├── migrations/        # Database migrations
│   │   └── seeds.exs          # Seed data (admin user)
│   │
│   └── static/                # Static assets (compiled)
│       ├── images/            # SVG logos, icons, patterns
│       │   ├── lumainus-logo-enhanced.svg    # Main logo (animated)
│       │   ├── icon-*.svg                    # Feature icons
│       │   └── patterns/                     # Background patterns
│       └── favicon.ico/.svg   # Favicons
│
├── config/                    # Configuration
│   ├── config.exs             # General config
│   ├── dev.exs                # Development config
│   ├── prod.exs               # Production config
│   └── runtime.exs            # Runtime config
│
├── test/                      # Test files
├── docs/                      # Documentation (HIPAA, FDA, etc.)
└── scripts/                   # Utility scripts
```

---

## Codebase Review Snapshot (Nov 16, 2025)

- `lib/lumainus/accounts/` owns users, invitations, session tokens, and `scope.ex`; everything that calls into contexts must pass a `Lumainus.Accounts.Scope` (see `lib/lumainus/accounts/scope.ex`) so role-aware queries stay centralized.
- `lib/lumainus_web/user_auth.ex` wires the plugs (`fetch_current_scope_for_user/2`, `require_*_role/2`, etc.) and handles remember-me cookies + session reissue logic; all LiveView mounts rely on the `current_scope` assign from this module.
- Authentication-facing LiveViews live in `lib/lumainus_web/live/user_live/` (login, registration, settings) and already follow `Layouts.app`; admin tooling resides in `lib/lumainus_web/live/admin/invitations_live.ex` and exercises `Lumainus.Accounts` end-to-end.
- `/reports` (`lib/lumainus_web/live/reports_live.ex`) now pulls from the real ingestion pipeline (PDF uploads + GeminiEx-powered markdown generation via the LLM facade). Use the `/prompts` editor to tweak prompts for each section or for the ingestion step.
- `/reports` performance: the bottleneck was preloading `llm_invocations.prompt_text/response_text` (~48MB for 13 runs). Latest section runs now preload a **shallow** LlmInvocation (id/provider/model/status/usage/req_duration_ms only). Do not add prompt/response/response_object to these preloads, and avoid reinstating ad hoc timing logs.
- Tailwind 4 lives in `assets/css/app.css` with the `@import "tailwindcss" source(none)` + `@source` directives; DaisyUI themes are registered inline so new components should stay compatible with this file rather than adding ad-hoc CSS frameworks.
- Tests are split between `test/lumainus_web` (contexts) and `test/lumainus_web_web/{controllers,live}` (router/auth/LiveView exercises). Add regression coverage next to whichever module you touch (ex: LiveView tests in `test/lumainus_web_web/live/*_test.exs`).
- Conversion resilience uses the Hex `retry` library—do not reimplement backoff/jitter; only wrap idempotent operations (health/status/SSE reconnect).

---

## Key Concepts & Architecture

### Authentication System
- **Passwordless Magic Links** - Primary authentication method
- **Password Auth** - Fallback option with "remember me"
- **Invitation System** - Admin-generated secure tokens for registration
- **Role Hierarchy:**
  1. `guest` - Read-only, basic access
  2. `doctor` - Medical professional, create/edit reports
  3. `admin` - User management, invitations, settings
  4. `system_administrator` - Full system control

### Phoenix LiveView Guidelines
- **Always use `Layouts.app`** for authenticated pages
- **Pass `current_scope` assign** (not `current_user`)
- **Access user via `@current_scope.user`** in templates
- **Use `live_session` scopes** properly:
  - `:current_user` - Pages that work with/without auth
  - `:require_authenticated_user` - Auth required
- **Never duplicate `live_session` names** - group all routes in one block

### CSS & Styling
- **Tailwind CSS 4** - New import syntax (no config file)
- **DaisyUI 5** - Component library (custom themes)
- **NO `@apply`** - Write manual Tailwind classes
- **Custom components over DaisyUI** - For unique branding
- **Embedded styles in templates** - For page-specific CSS

### Design Philosophy
- ✅ **Calm, serene, minimal** - Medical waiting room aesthetic
- ✅ **Huge whitespace** - Breathing room, no clutter
- ✅ **Soft animations** - Gentle, reassuring movements
- ✅ **Light backgrounds** - Not dark/technical
- ✅ **Simple actions** - Low cognitive load
- ❌ **NO technical dashboards** - Doctors don't want to think
- ❌ **NO busy layouts** - One focal point at a time
- ❌ **NO software aesthetic** - Think spa, not SaaS

---

## File Modification Guidelines

### When Editing Templates (`.html.heex`)

**Good Practices:**
```elixir
# ✅ Use assigns with curly braces in attributes
<div id={@id} class={@class}>

# ✅ Use <%= %> for block constructs in tag bodies
<%= if @condition do %>
  <p>{@message}</p>
<% end %>

# ✅ Use list syntax for conditional classes
<a class={[
  "base-class",
  @active && "active-class",
  if(@highlight, do: "highlight", else: "normal")
]}>

# ✅ Use Phoenix.Component.form/1
<.form for={@form} id="my-form" phx-submit="save">
  <.input field={@form[:email]} type="email" />
</.form>
```

**Bad Practices:**
```elixir
# ❌ NEVER use <%= %> in attributes
<div id="<%= @invalid %>">

# ❌ NEVER use if/elsif (doesn't exist in Elixir)
<%= if condition do %>
<% elsif other_condition %>  # INVALID!
<% end %>

# ❌ Use cond for multiple conditions
<%= cond do %>
  <% condition1 -> %> ...
  <% condition2 -> %> ...
  <% true -> %> ...
<% end %>
```

### When Editing LiveViews (`.ex`)

**Always:**
1. **Import Layouts** - `alias LumainusWeb.Layouts`
2. **Use `to_form/2`** - Never pass changesets directly to templates
3. **Return socket** - All `handle_*` callbacks return `{:noreply, socket}`
4. **Use streams** - For collections (not regular lists)
5. **Pass `current_scope`** - To all context functions

**Example:**
```elixir
defmodule LumainusWeb.MyLive do
  use LumainusWeb, :live_view
  alias LumainusWeb.Layouts

  def mount(_params, _session, socket) do
    form = to_form(%{}, as: :my_form)
    {:ok, assign(socket, form: form)}
  end

  def handle_event("save", %{"my_form" => params}, socket) do
    # Process params
    {:noreply, socket}
  end
end
```

### When Editing Routes

**Important:**
- Check which `live_session` scope is appropriate
- Never duplicate `live_session` names
- Use existing scopes, don't create new ones
- Be explicit about pipeline (`:browser`, `:require_authenticated_user`)

**Example:**
```elixir
scope "/", LumainusWeb do
  pipe_through [:browser, :require_authenticated_user]

  live_session :require_authenticated_user,
    on_mount: [{LumainusWeb.UserAuth, :require_authenticated}] do
    live "/dashboard", DashboardLive, :index
    # Add more authenticated routes here
  end
end
```

---

## Common Tasks

### 1. Creating a New Page

**For Public Pages:**
```bash
# 1. Create the LiveView module
# lib/lumainus_web/live/my_page_live.ex

# 2. Add route to router.ex (in :current_user scope)
live "/my-page", MyPageLive, :index

# 3. Create template if needed (or use inline ~H"""""")
```

**For Authenticated Pages:**
```bash
# Add to :require_authenticated_user scope instead
```

### 2. Adding Static Assets

**SVG Icons/Images:**
```bash
# Place in: priv/static/images/
# Reference as: ~p"/images/my-icon.svg"
```

**Background Patterns:**
```bash
# Place in: priv/static/images/patterns/
# Use in CSS: background-image: url('/images/patterns/my-pattern.svg');
```

### 3. Running the Application

```bash
# Install dependencies
mix setup

# Start server
mix phx.server

# Access at:
http://localhost:4000

# Dev mailbox (for magic links):
http://localhost:4000/dev/mailbox
```

### 4. Database Operations

```bash
# Create migration
mix ecto.gen.migration migration_name

# Run migrations
mix ecto.migrate

# Reset database
mix ecto.reset

# Seed admin user
mix run priv/repo/seeds.exs
```

### 5. Code Quality

```bash
# Format code
mix format

# Run precommit checks
mix precommit

# Run tests
mix test
```

---

## Design System

### Color Palette

**Primary Blues:**
- `#3b82f6` - Primary blue (buttons, links)
- `#60a5fa` - Light blue (highlights, hover)
- `#2563eb` - Dark blue (gradients)
- `#1e40af` - Deep blue (depth)

**Accent Colors:**
- `#8b5cf6` - Purple (innovation, AI)
- `#6366f1` - Indigo (secondary actions)
- `#06b6d4` - Cyan (info, alerts)
- `#10b981` - Green (success, positive metrics)
- `#f59e0b` - Amber (warnings, moderate confidence)

**Neutrals (Light Mode - Preferred):**
- `#f8fafc` - Lightest gray (backgrounds)
- `#f1f5f9` - Very light gray
- `#e2e8f0` - Light gray
- `#cbd5e1` - Medium light (secondary text)
- `#94a3b8` - Medium (muted text)
- `#64748b` - Medium dark (labels)
- `#1e293b` - Almost black (primary text)

### Typography

**Font Stack:**
```css
-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif
```

**Scale:**
- Display: 2.5rem - 4rem (clamp for responsive)
- Heading 1: 2rem - 2.5rem
- Heading 2: 1.5rem - 2rem
- Body: 1rem - 1.125rem
- Small: 0.875rem
- Tiny: 0.75rem

**Weights:**
- Light: 300 (display text)
- Regular: 400 (body)
- Medium: 500 (emphasis)
- Semibold: 600 (headings)
- Bold: 700 (strong emphasis)

### Spacing

Use Tailwind spacing scale, but prefer **larger gaps** for calm aesthetic:
- Sections: `4rem` - `6rem` vertical spacing
- Components: `2rem` - `3rem` between elements
- Content: `1rem` - `1.5rem` standard padding

### Animation Principles

**Timing:**
- **Fast**: 0.15s - 0.3s (micro-interactions)
- **Medium**: 0.4s - 0.8s (page transitions)
- **Slow**: 1s - 3s (ambient animations)
- **Very Slow**: 8s+ (background breathing)

**Easing:**
- Standard: `ease-in-out`
- Exits: `ease-in`
- Entrances: `ease-out`
- Special: `cubic-bezier(0.4, 0, 0.2, 1)`

**Examples:**
```css
/* Breathing effect for backgrounds */
@keyframes breathe {
  0%, 100% { transform: scale(1); opacity: 1; }
  50% { transform: scale(1.1); opacity: 0.8; }
}

/* Gentle float for logos */
@keyframes float {
  0%, 100% { transform: translateY(0); }
  50% { transform: translateY(-15px); }
}
```

**Always respect `prefers-reduced-motion`:**
```css
@media (prefers-reduced-motion: reduce) {
  * {
    animation: none !important;
    transition: none !important;
  }
}
```

---

## SVG Assets

### Logo Variants

**Primary Logo:**
- `lumainus-logo-enhanced.svg` - Animated, multi-layer effects
- Use for: Homepage, login page, main branding
- Size: 120px - 200px typically

**Icon Logo:**
- `favicon.svg` / `favicon.ico` - Compact version
- Use for: Favicon, small spaces
- Size: 32px - 64px

### Feature Icons

- `icon-transparency.svg` - Full transparency feature
- `icon-audit.svg` - 6-year audit trails
- `icon-network.svg` - Multi-agent verification

Usage: 32px - 48px, can be tinted with CSS filters

### Background Patterns

**Location:** `priv/static/images/patterns/`

1. **Neural Network Pattern** (`neural-network-pattern.svg`)
   - Interconnected nodes, data pulses
   - Use: Technical backgrounds, AI themes
   - Opacity: 0.1 - 0.3

2. **Traceable Pathways** (`traceable-pathways-pattern.svg`)
   - Decision trees, flowing branches
   - Use: Decision-making contexts
   - Opacity: 0.15 - 0.35

3. **Medical Tech** (`medical-tech-pattern.svg`)
   - Hexagonal molecular grid
   - Use: Clinical/medical pages
   - Opacity: 0.02 - 0.25 (very subtle)

4. **Data Visualization** (`data-viz-pattern.svg`)
   - Charts, confidence intervals
   - Use: Analytics, metrics pages
   - Opacity: 0.2 - 0.3

**Usage Example:**
```css
.background {
  background-image: url('/images/patterns/medical-tech-pattern.svg');
  background-size: 800px 800px;
  opacity: 0.02;
}
```

---

## Page-Specific Guidelines

### Homepage (`home.html.heex`)

**Theme:** "Serene Medical Sanctuary"

**Key Requirements:**
- ✅ Light gradient background (grays, soft blues)
- ✅ Single central focal point (logo)
- ✅ Minimal text (3-4 lines max)
- ✅ One clear CTA button ("Enter")
- ✅ Soft organic shapes (breathing animations)
- ✅ Lots of whitespace
- ❌ NO panels, columns, grids
- ❌ NO technical metrics or data
- ❌ NO dark mode aesthetic

**Structure:**
```heex
<div class="lumainus-sanctuary">
  <!-- Soft background shapes -->
  <!-- Floating logo (centerpiece) -->
  <!-- Brand name (elegant typography) -->
  <!-- Simple tagline (reassuring) -->
  <!-- Single CTA button -->
  <!-- Minimal trust indicators -->
  <!-- Subtle footer -->
</div>
```

### Login Page (`login.ex`)

**Theme:** "Medical AI Waiting Room"

**Key Requirements:**
- ✅ Full-screen immersive experience
- ✅ Animated background (neural patterns)
- ✅ Glass morphism card (frosted blur)
- ✅ Floating logo with animations
- ✅ Brand tagline visible
- ✅ Hide root layout menu (via CSS)
- ❌ NO default layout wrapper

**Structure:**
```elixir
# Standalone page, not wrapped in Layouts.app
# Embedded <style> tags for page-specific CSS
# Hide menu: body:has(.lumainus-login-page) > ul.menu { display: none; }
```

### Dashboard Pages (Future)

**Theme:** TBD - Will blend calm aesthetic with necessary data

**Considerations:**
- Show metrics without overwhelming
- Use cards sparingly
- Emphasize critical information
- Maintain breathing room

### Reports LiveView (`reports_live.ex`)

**Theme:** "Clinical source-of-truth workspace"

**Key Requirements:**
- Initialize assigns just like `ReportsLive.mount/3` (`documents`, `report`, `selected_document`, `document_view_mode`) so the sidebar + detail pane stay synchronized.
- Document selection is handled through `"select_document"`, `"show_source"`, and `"close_document"` events; keep the payload keys (`"doc-id"`, `"mode"`) stable because tests/assertions expect these atoms.
- Inline CSS at the top of `render/1` (see `lib/lumainus_web/live/reports_live.ex:54+`) intentionally builds the clinical chart aesthetic; edit the existing selectors instead of scattering new style tags elsewhere.
- When changing report sections, update the prompt templates via `/prompts` and ensure the corresponding ingestion+LLM schema matches the UI expectations.
- Provenance badges pull from stored `DocumentUpload` records; make sure ingestion jobs capture the metadata (`label`, `summary`, `provider`) you expect the UI to surface.
- Per-user Docling backend selector (“Processing speed: Standard / Fast”). Preference is stored on the user record (`users.docling_backend`, default `"local"`). Disable Fast when remote health fails; fallback to Standard without breaking uploads.

---

## Development Workflows

### Pre-Commit Checklist

Before committing code:
```bash
# 1. Format code
mix format

# 2. Run precommit checks
mix precommit

# 3. Run tests (if applicable)
mix test

# 4. Check for compilation warnings
mix compile --warnings-as-errors

# 5. Verify changes
git diff
```

### Deployment Process

```bash
# 1. Ensure all changes committed
git status

# 2. Push to main
git push origin main

# 3. Deployment happens automatically via scripts/deploy.sh
# Or manually:
./scripts/deploy.sh
```

### Testing Authentication

```bash
# 1. Seed admin user
mix run priv/repo/seeds.exs

# 2. Visit login page
open http://localhost:4000/users/log-in

# 3. Enter: admin@lumainus.local

# 4. Check mailbox for magic link
open http://localhost:4000/dev/mailbox

# 5. Click link to log in
```

### Testing Concurrency & HTTP

- Prefer `Supertester` isolation (or `Lumainus.Conversion.TestCase`) for OTP-heavy tests; avoid `Process.sleep/1`—use monitors, telemetry, or supervised processes instead.
- For Bypass-based HTTP/SSE tests, ensure expectations are consumed (choose `stub` vs `expect` appropriately) and clean up streams/processes via `on_exit`.
- Use the Hex `retry` library for backoff/jitter—do not implement custom sleep loops.
- Start required pools (e.g., Finch) inside tests when isolating; keep them supervised and unlinked to avoid registry leaks.
- CI note: test Repo uses `ownership_timeout: 300_000` and `migration_lock: nil` to prevent migration lock timeouts on shared runners. Retain these unless you also adjust CI database setup.

---

## Common Pitfalls & Solutions

### Issue: Flash messages not displaying

**Problem:** Using `<.flash_group>` outside Layouts module
**Solution:** Use `<Layouts.flash_group flash={@flash} />`

### Issue: `current_user` undefined

**Problem:** Trying to access `@current_user` in templates
**Solution:** Use `@current_scope.user` instead

### Issue: Form not submitting

**Problem:** Not using `to_form/2` or passing changeset directly
**Solution:** Always use `to_form(changeset)` and pass to template

### Issue: Animations not working

**Problem:** User has `prefers-reduced-motion` enabled
**Solution:** This is intentional, respect accessibility preferences

### Issue: Favicon showing blank

**Problem:** Old digested version cached
**Solution:** Delete `priv/static/favicon-*.ico` and rebuild

### Issue: CSS not applying

**Problem:** Tailwind not finding classes in template
**Solution:** Ensure `@source` paths in `app.css` include your template directory

---

## Security Considerations

### Authentication
- **NEVER** skip CSRF protection
- **ALWAYS** use Phoenix.Token for magic links
- **NEVER** log passwords or tokens
- **ALWAYS** use prepared statements (Ecto does this)

### Authorization
- **ALWAYS** pass `current_scope` to context functions
- **NEVER** trust client-side role checks
- **ALWAYS** filter queries by `current_scope.user`

### HIPAA Compliance
- **NEVER** log PHI (Protected Health Information)
- **ALWAYS** use secure sessions
- **NEVER** expose patient data in URLs
- **ALWAYS** implement audit trails

---

## Resources & References

### Documentation
- **Phoenix Framework:** https://hexdocs.pm/phoenix
- **Phoenix LiveView:** https://hexdocs.pm/phoenix_live_view
- **Ecto:** https://hexdocs.pm/ecto
- **Tailwind CSS:** https://tailwindcss.com
- **DaisyUI:** https://daisyui.com

### Project Docs
- `README.md` - Setup and installation
- `DEVELOPMENT.md` - Development guidelines
- `DEPLOYMENT.md` - Deployment instructions
- `docs/` - HIPAA, FDA, compliance documentation

### Internal Docs
- `docs/20251116/001_LUMAINUS_claude.md` - AI architecture vision
- Design concepts documented in `LUMAINUS_LOGIN_REDESIGN.md`

---

## Agent Instructions Summary

When working with this codebase:

1. **Read First:**
   - This file (AGENTS.md)
   - README.md
   - Any existing page templates you're modifying

2. **Design Philosophy:**
   - CALM over clever
   - SIMPLE over sophisticated
   - BREATHABLE over busy
   - LIGHT over dark
   - MINIMAL over maximal

3. **Code Style:**
   - Follow Phoenix 1.8 conventions
   - Use LiveView best practices
   - Respect Elixir idioms
   - Write readable, simple code

4. **Communication:**
   - Ask before making architectural changes
   - Explain design decisions
   - Show before/after for UI changes
   - Document non-obvious code

5. **Testing:**
   - Run `mix precommit` before committing
   - Test authentication flows
   - Verify responsive design
   - Check accessibility

---

**For Questions or Issues:**
- Check this file first
- Review Phoenix/LiveView docs
- Search existing code for patterns
- Ask user for clarification on design decisions

**Last Updated:** November 23, 2025
**Maintainer:** AI Agents working on Lumainus project

---

## Telemetry Follow-Up Addendum (2025-11-20)

For ongoing Docling ingestion work:
- Default Docling queue mode is set to `:http_queue` in `config/config.exs` (test env remains inline). Docling service exposes `/jobs/:id/stream` (SSE) and `/jobs/:id/status`; prefer SSE when available, otherwise poll.
- LiveView crash on timeout values is fixed; `format_timeout_remaining/1` accepts both `DateTime` structs and ISO strings.
- Docling progress updates are deduped server-side to reduce churn; intermediate Docling polling updates do not broadcast document reloads.

---

## Docling 5-Backend Architecture (Updated 2025-11-28)

### Port Assignments (Standardized)

| Port | Backend | Type | Description |
|------|---------|------|-------------|
| **8040** | `native_cpu` | Local | Host Python/uvicorn, CPU only |
| **8041** | `native_gpu` | Local | Host Python/uvicorn, CUDA GPU |
| **8042** | `docker_cpu` | Local | Docker container, CPU mode |
| **8043** | `docker_gpu` | Local | Docker container, GPU mode |
| **8044** | `vast_ai` | Cloud | Vast.ai remote GPU ($$$) |

### User-Facing Modes

- **Local (free)**: Admin selects which of the 4 local backends is active via `/admin/docling`
- **Cloud ($$$)**: Vast.ai GPU - costs money, users opt-in

Users choose between "Local" and "Cloud" in `/reports`. The choice is stored on `users.docling_backend`.

### Key Configuration

```elixir
# config/config.exs
config :lumainus, :docling,
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

### Key Files

| File | Purpose |
|------|---------|
| `scripts/docling-ports.env` | Central port definitions (source in scripts) |
| `scripts/docling-compose.sh` | Docker Compose management (interactive menu) |
| `scripts/docling-gpu.sh` | Docker image management (build/run/push) |
| `scripts/setup_docling_service.sh` | Native Python setup |
| `lib/lumainus/docling.ex` | Backend resolution logic |
| `lib/lumainus/docling/setting.ex` | Schema (5 URLs + settings) |
| `lib/lumainus/docling/settings.ex` | Persistence layer |
| `lib/lumainus_web/live/admin/docling_settings_live.ex` | Admin UI |
| `docker-compose.yml` | Docker service definitions |

### Running Backends

```bash
# Docker Compose (recommended)
./scripts/docling-compose.sh          # Interactive menu
docker compose up -d docling-cpu      # Start CPU on 8042
docker compose --profile gpu up -d    # Start GPU on 8043

# Docker image management
./scripts/docling-gpu.sh              # Interactive menu
./scripts/docling-gpu.sh run-cpu      # Direct command

# Native Python (no Docker)
./scripts/setup_docling_service.sh native_cpu  # Port 8040
./scripts/setup_docling_service.sh native_gpu  # Port 8041
```

### Schema Changes

The `docling_settings` table now includes:
- `default_mode` - User default (local/cloud)
- `active_local_backend` - Which local backend is active
- `native_cpu_url`, `native_gpu_url`, `docker_cpu_url`, `docker_gpu_url`, `cloud_url`

Run `mix ecto.migrate` to apply the expansion migration.

### Agent Notes

- **Port source of truth**: `scripts/docling-ports.env` - always source this in new scripts
- **Backend resolution**: `Lumainus.Docling.backend_name_from_opts/1` handles mode → backend mapping
- **URL lookup**: `Lumainus.Docling.url_for_backend/1` returns the URL for any backend type
- **Health checks**: Admin UI at `/admin/docling` shows health for all 5 backends
- **User choice**: Stored as `"local"` or `"cloud"` on `users.docling_backend`
- **Tests**: Use Bypass mocks; set `prefer_env_overrides: true` in test config
- **URL safety**: Must use `https://` unless localhost/127.0.0.1
- **Progress latency debugging**: Enable `[docling-progress-debug]` logging by setting `config :lumainus, :docling, debug_progress_log: true`

---

## SSE Streaming Architecture (Updated 2025-11-28)

### Communication Flow

```
Python (docling_service)
    └── GET /jobs/{job_id}/stream (SSE endpoint)
            │
            ▼
Elixir (SSEStream.await)
    └── Opens SSE connection via Finch
    └── Blocks waiting for events
    └── Calls on_status callback for each event
    └── Returns {:ok, status} or {:error, reason} on terminal state
            │
            ▼
Backends (LocalBackend/CloudBackend)
    └── Use SSEStream.await for real-time progress
```

**NO HTTP polling.** All progress updates come via Server-Sent Events.

### Key Files

| File | Purpose |
|------|---------|
| `lib/lumainus/conversion/infrastructure/http/sse_stream.ex` | SSE client with reconnection, heartbeat |
| `lib/lumainus/conversion/infrastructure/http/client.ex` | HTTP client (enqueue, status, health, cancel) |
| `lib/lumainus/conversion/backends/local_backend.ex` | Local backend using SSEStream.await |
| `lib/lumainus/conversion/backends/cloud_backend.ex` | Cloud backend using SSEStream.await |
| `docling_service/app/main.py` | FastAPI service with SSE endpoint |

### SSEStream Features

- **Automatic reconnection** with exponential backoff: [1s, 2s, 5s, 10s, 30s]
- **Heartbeat monitoring** (default 60s timeout)
- **JSON event parsing** with terminal state detection
- **Blocking await** interface for synchronous callers

### Progress Calculation

Progress is calculated in `main.py` from pages, NOT passed through from docling:

```python
# docling_service/app/main.py - _docling_progress_cb
if job.pages_total and job.pages_total > 0:
    calculated = round((job.pages_done / job.pages_total) * 100.0, 2)
    job.progress = min(max(calculated, 0.0), 100.0)
```

This ensures:
- Progress is always 0-100 scale with 2 decimal places
- Progress never exceeds 100%
- Progress is derived from reliable page counts, not docling's internal (unreliable) progress field

---

## DockerManager Auto-Start (Updated 2025-11-28)

### Behavior

When `mix phx.server` starts, `DockerManager` GenServer automatically runs:

```bash
docker compose up -d --force-recreate docling-cpu
```

The `--force-recreate` flag ensures:
- Container is recreated even if already running
- Volume-mounted changes (like `main.py`) are picked up immediately
- No manual Docker restart needed after code changes

### Key Code

`lib/lumainus/docling/docker_manager.ex`:
- **Starts on Phoenix boot** via Application supervisor
- **Stops container on Phoenix shutdown**
- **Monitors health** and restarts if container dies
- **Uses --force-recreate** for startup (lines 148-156, 197-205)

### Implication for Development

**Just restart Phoenix.** Docker container restarts automatically with latest volume-mounted code.

---

## Forked Docling Library (Updated 2025-11-28)

### Location

The project includes a forked version of the Docling library:

```
lumainus/
├── docling/                    # Forked docling library
│   └── docling/
│       └── pipeline/
│           ├── base_pipeline.py
│           └── standard_pdf_pipeline.py
└── docling_service/           # FastAPI wrapper service
    └── app/
        └── main.py            # Volume-mounted, changes apply immediately
```

### What's Volume-Mounted vs Baked

| Component | Location | How Changes Apply |
|-----------|----------|-------------------|
| `docling_service/app/` | Volume-mounted | Immediate on container restart |
| `docling/` (forked library) | Baked into Docker image | Requires image rebuild |

### Rebuilding the Base Image

If you change files in `docling/docling/pipeline/`:

```bash
./scripts/docling-gpu.sh build-base   # ~10 minutes
```

This rebuilds `ghcr.io/nshkrdotcom/lumainus-docling-gpu:latest` with the forked docling code.

### Dockerfile Structure

`docling_service/Dockerfile.gpu-base` (lines 28-30):
```dockerfile
COPY docling /app/docling
RUN pip install -e /app/docling
```

---

## Database: Progress as Float (2025-11-28)

Migration `20251129021313_change_conversion_jobs_progress_to_float.exs`:

```elixir
alter table(:conversion_jobs) do
  modify(:progress, :float, default: 0.0)
end
```

Progress is now stored as FLOAT with 2 decimal places (e.g., 45.67% not 45%).

---

## Gemini Rate Limiting Integration (2025-12-03)

### Overview

The project uses `gemini_ex` 0.5.0+ which includes automatic rate limiting to prevent 429 quota errors during admin report generation. Rate limiting is **enabled by default** with conservative settings.

### Configuration

Rate limiter settings in `config/config.exs`:

```elixir
config :gemini_ex, :rate_limiter,
  max_concurrency_per_model: 2,    # Conservative limit for concurrent requests
  max_attempts: 4,                  # Retry attempts on transient errors
  base_backoff_ms: 1500,           # Base backoff with exponential + jitter
  adaptive_concurrency: true,       # Reduces concurrency on 429s, increases on success
  adaptive_ceiling: 4,              # Max concurrency adaptive mode can reach
  profile: :prod
```

### Key Behaviors

1. **Automatic Rate Limiting**: All Gemini API requests go through the rate limiter automatically
2. **Concurrency Gating**: Limits concurrent requests per model to prevent quota exhaustion
3. **Automatic Retries**: Retries with exponential backoff on 429 and transient errors
4. **Adaptive Mode**: Dynamically adjusts concurrency based on API responses
5. **Streaming Safe**: Rate limiter only gates request submission; open streams are not interrupted

### Structured Errors

The `Lumainus.LLM` module handles gemini_ex structured errors:

- `{:error, {:rate_limited, retry_at, details}}` → Formatted with retry timing info
- `{:error, {:transient_failure, attempts, original_error}}` → Formatted with attempt count

These are stored in the `error` field of `ReportSectionRun` with structured details.

### Troubleshooting

If reports still fail with 429s:

1. **Lower concurrency further**: Set `max_concurrency_per_model: 1` in config
2. **Reduce parallelism at app level**: Limit concurrent section generation in Oban queues
3. **Check quotas**: Verify Gemini API quota limits in Google Cloud Console
4. **Review logs**: Look for `[SectionRunner] LLM generation failed` messages

### Environment Variables

- `GEMINI_API_KEY` or `GOOGLE_API_KEY`: Gemini API key (set in `config/runtime.exs`)

### Key Files

| File | Purpose |
|------|---------|
| `config/config.exs` | Global rate limiter configuration |
| `lib/lumainus/llm.ex` | Gemini client facade with error handling |
| `lib/lumainus/ai/section_runner.ex` | Section generation that uses LLM client |

### Agent Notes

- Rate limiter config is in `config.exs`, not env-specific configs
- Do not add manual sleeps or delays; rely on gemini_ex rate limiter
- The `MockClient` in tests bypasses rate limiting (no network calls)
- Monitor telemetry events `[:gemini, :rate_limit, ...]` for rate limit insights
