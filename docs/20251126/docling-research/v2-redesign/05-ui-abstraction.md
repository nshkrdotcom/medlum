# v2 UI Abstraction

**Date:** November 26, 2025

---

## Overview

The v2 architecture completely decouples the UI from backend implementation details. Users see only:

- **Processing profiles**: Standard or Enhanced
- **Job status**: Simple states (Queued, Processing, Complete, Error)
- **Progress**: Percentage and friendly messages

The UI has **ZERO knowledge** of:
- Backend names (docker_cpu, native_gpu, vast_ai)
- Port numbers (8040-8044)
- Backend URLs
- Health check details
- Circuit breaker states
- SSE vs polling implementation

---

## Before vs After

### Before (Current)

```heex
<%# User sees backend details %>
<button phx-click="set_docling_backend" phx-value-backend="cloud">
  Fast (GPU) - Cloud
</button>

<span class="text-xs">
  <%= if @docling_backend == :cloud do %>
    Fast uses remote GPU processing...
  <% else %>
    Standard uses the local CPU Docling service.
  <% end %>
</span>

<%# Document shows backend %>
<span class="badge">{backend_label(doc.backend)}</span>

<%# Health status exposed %>
<%= if @fast_available? == nil do %>
  Checking...
<% else if @fast_available? == false do %>
  <%= if String.contains?(@fast_unavailable_reason, "starting") do %>
    Starting up...
  <% end %>
<% end %>
```

### After (v2)

```heex
<%# User sees only profile %>
<.profile_selector
  selected={@processing_profile}
  profiles={@available_profiles}
  on_change="set_profile"
/>

<%# Simple availability indicator %>
<.availability_indicator available={@enhanced_available} />

<%# Document shows nothing about backend %>
<%# (or optionally just a subtle icon) %>
```

---

## User-Facing Components

### Profile Selector

```elixir
defmodule MedlumWeb.Components.Conversion do
  @moduledoc """
  Conversion-related UI components with no backend knowledge.
  """

  use Phoenix.Component
  alias Medlum.Conversion.ProcessingProfile

  @doc """
  Profile selection component.
  Shows "Standard" and "Enhanced" options with no backend details.
  """
  attr :selected, :atom, required: true
  attr :profiles, :list, required: true
  attr :on_change, :string, required: true
  attr :disabled, :boolean, default: false

  def profile_selector(assigns) do
    ~H"""
    <div class="flex gap-2" role="radiogroup" aria-label="Processing speed">
      <%= for profile <- @profiles do %>
        <button
          type="button"
          role="radio"
          aria-checked={@selected == profile}
          phx-click={@on_change}
          phx-value-profile={profile}
          disabled={@disabled}
          class={profile_button_class(@selected == profile)}
        >
          {ProcessingProfile.label(profile)}
          <%= if ProcessingProfile.may_have_cost?(profile) do %>
            <span class="text-xs opacity-70 ml-1">$$</span>
          <% end %>
        </button>
      <% end %>
    </div>
    """
  end

  defp profile_button_class(true) do
    "rounded-full border px-3 py-1 text-xs font-semibold bg-slate-900 text-white border-slate-900"
  end

  defp profile_button_class(false) do
    "rounded-full border px-3 py-1 text-xs font-semibold bg-white text-slate-700 border-slate-200 hover:border-slate-300"
  end
end
```

### Job Status Display

```elixir
@doc """
Job status display with user-friendly messages.
"""
attr :status, :map, required: true

def job_status(assigns) do
  ~H"""
  <div class="flex items-center gap-2">
    <.status_icon state={@status.state} />
    <span class="text-sm">
      {status_message(@status)}
    </span>
    <%= if @status.state == :processing do %>
      <.progress_bar progress={@status.progress} />
    <% end %>
  </div>
  """
end

defp status_icon(%{state: :queued} = assigns) do
  ~H"""
  <span class="w-2 h-2 rounded-full bg-slate-400 animate-pulse"></span>
  """
end

defp status_icon(%{state: :processing} = assigns) do
  ~H"""
  <span class="w-2 h-2 rounded-full bg-blue-500 animate-pulse"></span>
  """
end

defp status_icon(%{state: :completed} = assigns) do
  ~H"""
  <span class="w-2 h-2 rounded-full bg-green-500"></span>
  """
end

defp status_icon(%{state: :failed} = assigns) do
  ~H"""
  <span class="w-2 h-2 rounded-full bg-red-500"></span>
  """
end

defp status_message(%{state: :queued}), do: "Waiting to start"
defp status_message(%{state: :processing, message: nil, progress: p}), do: "Processing (#{p}%)"
defp status_message(%{state: :processing, message: msg}), do: msg
defp status_message(%{state: :completed}), do: "Complete"
defp status_message(%{state: :failed, error: nil}), do: "Failed"
defp status_message(%{state: :failed, error: error}), do: error
defp status_message(%{state: :cancelled}), do: "Cancelled"
```

### Availability Indicator

```elixir
@doc """
Simple availability indicator for enhanced processing.
No backend details exposed.
"""
attr :available, :boolean, default: nil

def availability_indicator(assigns) do
  ~H"""
  <%= case @available do %>
    <% nil -> %>
      <%# Still checking - show nothing or subtle loading %>
      <span class="text-xs text-slate-400">...</span>

    <% true -> %>
      <%# Available - show nothing (default state) %>

    <% false -> %>
      <%# Unavailable - subtle indicator %>
      <span class="text-xs text-slate-500">
        Enhanced processing unavailable
      </span>
  <% end %>
  """
end
```

### Progress Bar

```elixir
@doc """
Progress bar component.
"""
attr :progress, :integer, required: true

def progress_bar(assigns) do
  ~H"""
  <div class="w-24 h-1 bg-slate-200 rounded-full overflow-hidden">
    <div
      class="h-full bg-blue-500 transition-all duration-300"
      style={"width: #{@progress}%"}
    />
  </div>
  """
end
```

---

## ReportsLive Refactored

### Before

```elixir
defmodule MedlumWeb.ReportsLive do
  # 1900+ lines with backend details throughout

  def mount(_params, _session, socket) do
    # ...
    socket
    |> assign(:docling_backend, user.docling_backend || :local)
    |> assign(:fast_available?, nil)
    |> assign(:fast_unavailable_reason, nil)
    # ...
  end

  def handle_event("set_docling_backend", %{"backend" => backend}, socket) do
    backend_atom = String.to_existing_atom(backend)
    # ... 30+ lines of backend switching logic
  end

  def handle_info({:gpu_status_changed, status_map}, socket) do
    # ... complex GPU status handling
  end

  # Many more backend-aware functions...
end
```

### After

```elixir
defmodule MedlumWeb.ReportsLive do
  @moduledoc """
  Reports LiveView with no conversion backend knowledge.
  """

  use MedlumWeb, :live_view

  alias Medlum.Conversion.Service, as: ConversionService
  alias MedlumWeb.Components.Conversion

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to conversion events (profile availability changes)
      ConversionService.subscribe()
    end

    {:ok,
     socket
     |> assign_user_profile()
     |> assign_available_profiles()}
  end

  # Profile Selection

  def handle_event("set_profile", %{"profile" => profile}, socket) do
    profile_atom = String.to_existing_atom(profile)

    case update_user_profile(socket.assigns.current_user, profile_atom) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(:processing_profile, profile_atom)
         |> put_flash(:info, "Processing preference updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update preference")}
    end
  end

  # Document Upload

  def handle_event("upload_document", _params, socket) do
    consume_uploaded_entries(socket, :documents, fn %{path: path}, entry ->
      binary = File.read!(path)

      case ConversionService.submit(binary,
        filename: entry.client_name,
        profile: socket.assigns.processing_profile,
        tenant_id: socket.assigns.tenant.id,
        user_id: socket.assigns.current_user.id
      ) do
        {:ok, job} ->
          {:ok, job}

        {:error, reason} ->
          {:error, humanize_error(reason)}
      end
    end)

    {:noreply, socket}
  end

  # Conversion Events

  def handle_info({:conversion_profiles_changed, profiles}, socket) do
    {:noreply, assign(socket, :available_profiles, profiles)}
  end

  def handle_info({:conversion_job_progress, job_id, status}, socket) do
    {:noreply, update_job_status(socket, job_id, status)}
  end

  def handle_info({:conversion_job_completed, job_id, result}, socket) do
    {:noreply,
     socket
     |> update_job_status(job_id, %{state: :completed})
     |> maybe_refresh_documents()}
  end

  # Private

  defp assign_user_profile(socket) do
    user = socket.assigns.current_user
    profile = user.preferences[:processing_profile] || :standard
    assign(socket, :processing_profile, profile)
  end

  defp assign_available_profiles(socket) do
    profiles = ConversionService.profiles()
    enhanced_available = :enhanced in profiles

    socket
    |> assign(:available_profiles, profiles)
    |> assign(:enhanced_available, enhanced_available)
  end

  defp humanize_error(:file_too_large), do: "File is too large (max 100 MB)"
  defp humanize_error(:invalid_file_type), do: "Only PDF files are supported"
  defp humanize_error(:invalid_pdf), do: "File does not appear to be a valid PDF"
  defp humanize_error(:too_many_jobs), do: "Too many documents processing, please wait"
  defp humanize_error(_), do: "Could not process document"
end
```

### Template

```heex
<div class="reports-container">
  <%# Profile selector - simple, no backend details %>
  <div class="mb-4">
    <Conversion.profile_selector
      selected={@processing_profile}
      profiles={@available_profiles}
      on_change="set_profile"
    />
    <Conversion.availability_indicator available={@enhanced_available} />
  </div>

  <%# Document list %>
  <div class="documents-grid">
    <%= for doc <- @documents do %>
      <.document_card document={doc} />
    <% end %>
  </div>

  <%# Processing status for in-flight jobs %>
  <%= for {job_id, status} <- @active_jobs do %>
    <div class="processing-indicator">
      <Conversion.job_status status={status} />
    </div>
  <% end %>
</div>
```

---

## Document Display

### Before

```heex
<%# Backend badge on every document %>
<span class={backend_badge_class(doc.backend, doc.backend_status)}>
  {backend_label(doc.backend)}
</span>
```

### After

```heex
<%# NO backend indicator on documents %>
<%# Or, if needed, just a subtle performance indicator: %>

<%= if doc.metadata[:was_enhanced] do %>
  <span class="text-xs text-slate-400" title="Processed with enhanced speed">
    <.icon name="hero-bolt" class="w-3 h-3" />
  </span>
<% end %>
```

The document metadata stores only whether enhanced processing was used (boolean), not which specific backend processed it.

---

## Admin UI (Separate from User UI)

Backend configuration is **ONLY** in admin UI:

```elixir
defmodule MedlumWeb.Admin.ConversionSettingsLive do
  @moduledoc """
  Admin-only view for conversion infrastructure configuration.
  Users never see this.
  """

  use MedlumWeb, :live_view

  # This is where backend URLs, ports, health status belong
  # Completely separate from user-facing ReportsLive
end
```

### Admin-Only Information

| Information | User UI | Admin UI |
|-------------|---------|----------|
| Processing profile | Yes | Yes |
| Profile availability | Yes (boolean) | Yes (with reason) |
| Backend names | No | Yes |
| Port numbers | No | Yes |
| Backend URLs | No | Yes |
| Health check details | No | Yes |
| Circuit breaker state | No | Yes |
| Error details | Humanized | Full details |
| Telemetry/metrics | No | Yes |

---

## Event Broadcasting

### ConversionService Events

The ConversionService broadcasts user-friendly events:

```elixir
defmodule Medlum.Conversion.Events do
  @moduledoc """
  User-facing conversion events.
  """

  @doc "Broadcast profile availability change"
  def profiles_changed(profiles) do
    Phoenix.PubSub.broadcast(
      Medlum.PubSub,
      "conversion:profiles",
      {:conversion_profiles_changed, profiles}
    )
  end

  @doc "Broadcast job progress"
  def job_progress(job_id, status) do
    # Status is JobStatus struct - already user-friendly
    Phoenix.PubSub.broadcast(
      Medlum.PubSub,
      "conversion:job:#{job_id}",
      {:conversion_job_progress, job_id, status}
    )
  end

  @doc "Broadcast job completion"
  def job_completed(job_id, result) do
    Phoenix.PubSub.broadcast(
      Medlum.PubSub,
      "conversion:job:#{job_id}",
      {:conversion_job_completed, job_id, result}
    )
  end

  @doc "Broadcast job failure"
  def job_failed(job_id, error) do
    # Error is humanized, not raw backend error
    Phoenix.PubSub.broadcast(
      Medlum.PubSub,
      "conversion:job:#{job_id}",
      {:conversion_job_failed, job_id, error}
    )
  end
end
```

### Subscribing

```elixir
# In LiveView mount
def mount(_params, _session, socket) do
  if connected?(socket) do
    # Subscribe to profile changes
    Phoenix.PubSub.subscribe(Medlum.PubSub, "conversion:profiles")

    # Subscribe to specific job updates
    for job_id <- active_job_ids(socket) do
      Phoenix.PubSub.subscribe(Medlum.PubSub, "conversion:job:#{job_id}")
    end
  end
end
```

---

## User Preferences

### Schema

```elixir
defmodule Medlum.Accounts.User do
  schema "users" do
    # ...existing fields...

    # Simple profile preference - NOT backend
    field :processing_profile, Ecto.Enum, values: [:standard, :enhanced], default: :standard

    # REMOVED: docling_backend field
    # No longer storing backend-level preference
  end
end
```

### Migration

```elixir
defmodule Medlum.Repo.Migrations.SimplifyUserProcessingPreference do
  use Ecto.Migration

  def up do
    # Add new simple field
    alter table(:users) do
      add :processing_profile, :string, default: "standard"
    end

    # Migrate existing data
    execute """
    UPDATE users
    SET processing_profile = CASE
      WHEN docling_backend IN ('cloud', 'fast', 'vast_ai') THEN 'enhanced'
      ELSE 'standard'
    END
    """

    # Remove old field
    alter table(:users) do
      remove :docling_backend
    end
  end

  def down do
    alter table(:users) do
      add :docling_backend, :string, default: "local"
      remove :processing_profile
    end
  end
end
```

---

## Summary: What Users See

### Profile Selection
- **Standard**: Free processing
- **Enhanced**: Faster processing (may cost $$)

### Status Messages
- "Waiting to start"
- "Processing page 3 of 10"
- "Complete"
- "Processing failed" (with humanized reason)

### Availability
- Enhanced available: nothing shown
- Enhanced unavailable: "Enhanced processing unavailable"

### Document List
- No backend badges
- Optional subtle icon if enhanced was used

### Error Messages
- "File is too large (max 100 MB)"
- "Only PDF files are supported"
- "Could not process document"

---

## What Users DON'T See

- `docker_cpu`, `native_gpu`, `vast_ai`
- Ports 8040, 8041, 8042, 8043, 8044
- `http://127.0.0.1:8042`
- "Circuit breaker open"
- "SSE connection failed, falling back to polling"
- "Vast.ai instance provisioning"
- "Health check: econnrefused"
- Instance IDs, GPU names, SSH details

---

## Next: Migration Plan

See [06-migration-plan.md](06-migration-plan.md) for phased implementation approach.
