# ADR-005: UI Architecture - LLM Config Studio

## Status
Proposed

## Context

The current `/prompts` page is minimal:
- Left sidebar: section list + ingestion prompt textarea
- Right panel: section prompt textarea
- Only 2 fields editable per section

The refactor requires exposing 20+ configurable fields per section, organized logically while remaining usable.

## Decision

Replace `/prompts` with a comprehensive "LLM Config Studio" at `/admin/llm-config` using a tabbed interface with collapsible sections.

### Page Layout

```
┌─────────────────────────────────────────────────────────────────┐
│ LLM Config Studio                                               │
│ Configure prompts, models, and output schemas for report gen.  │
├─────────────────────────────────────────────────────────────────┤
│ [Template Settings] [Sections ▼]                                │
├──────────────────┬──────────────────────────────────────────────┤
│                  │                                              │
│  SECTIONS        │  ┌─ Chief Complaint ─────────────────────┐   │
│  ─────────────   │  │                                       │   │
│  ● Chief Comp... │  │  [Prompts] [Model] [Output] [Advanced]│   │
│  ○ History of... │  │  ─────────────────────────────────────│   │
│  ○ Past History  │  │                                       │   │
│  ○ Medications   │  │  System Prompt                        │   │
│  ○ Physical Ex.. │  │  ┌───────────────────────────────┐    │   │
│  ○ Review of Sys │  │  │ You are a clinical...         │    │   │
│  ○ Lab Review    │  │  └───────────────────────────────┘    │   │
│  ○ Imaging Rev.. │  │                                       │   │
│  ○ Pathology...  │  │  User Prompt Template                 │   │
│  ○ Assessment    │  │  ┌───────────────────────────────┐    │   │
│  ○ Plan          │  │  │ Analyze <%= documents %>...   │    │   │
│                  │  │  └───────────────────────────────┘    │   │
│  ─────────────   │  │                                       │   │
│  PDF Ingestion   │  │  [Save Section]                       │   │
│  ┌────────────┐  │  └───────────────────────────────────────┘   │
│  │ Prompt...  │  │                                              │
│  └────────────┘  │                                              │
│  [Save]          │                                              │
└──────────────────┴──────────────────────────────────────────────┘
```

### Tab Structure Per Section

**Tab 1: Prompts**
- System Prompt (textarea, optional - inherits from template if empty)
- User Prompt Template (textarea, required)
- Available variables reference (collapsible)

**Tab 2: Model**
- Provider (select: google, anthropic, openai)
- Model (select, filtered by provider)
- Fallback Provider (select, optional)
- Fallback Model (select, optional)

**Tab 3: Generation**
- Temperature (range slider 0.0-2.0)
- Top P (range slider 0.0-1.0)
- Top K (number input)
- Max Output Tokens (number input)
- Candidate Count (number input, usually 1)

**Tab 4: Output**
- Output Schema (JSON editor with validation)
- Response Format (select: json, text)
- Schema validation status indicator

**Tab 5: Advanced**
- Stop Sequences (tag input)
- Presence Penalty (range slider -2.0 to 2.0)
- Frequency Penalty (range slider -2.0 to 2.0)
- Seed (number input, optional)
- Timeout (number input, ms)
- Max Retries (number input)
- Retry Delay (number input, ms)
- Auto-run (checkbox)

### Component Implementation

```elixir
defmodule LumainusWeb.Admin.LlmConfigLive do
  use LumainusWeb, :live_view

  alias Lumainus.Reports

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    template = Reports.default_template_for_scope(scope)
    sections = template.sections
    selected = List.first(sections)

    {:ok,
     socket
     |> assign(:template, template)
     |> assign(:sections, sections)
     |> assign(:selected_section, selected)
     |> assign(:active_tab, "prompts")
     |> assign(:section_form, section_form(selected))
     |> assign(:template_form, template_form(template))
     |> assign(:schema_valid, true)
     |> assign(:schema_error, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto py-8 px-6">
      <.page_header
        title="LLM Config Studio"
        subtitle="Configure prompts, models, and output schemas for report generation."
      />

      <div class="grid gap-6 lg:grid-cols-4 mt-8">
        <!-- Sidebar -->
        <div class="space-y-4">
          <.section_list
            sections={@sections}
            selected={@selected_section}
          />
          <.ingestion_prompt_card
            form={@template_form}
          />
        </div>

        <!-- Main Panel -->
        <div class="lg:col-span-3">
          <.section_config_panel
            section={@selected_section}
            form={@section_form}
            active_tab={@active_tab}
            schema_valid={@schema_valid}
            schema_error={@schema_error}
          />
        </div>
      </div>
    </div>
    """
  end

  # Tab navigation
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  # Section selection
  def handle_event("select_section", %{"id" => id}, socket) do
    section = Enum.find(socket.assigns.sections, &(&1.id == id))
    {:noreply,
     socket
     |> assign(:selected_section, section)
     |> assign(:section_form, section_form(section))
     |> assign(:active_tab, "prompts")}
  end

  # Schema validation (debounced)
  def handle_event("validate_schema", %{"schema_json" => json}, socket) do
    case validate_schema_json(json) do
      {:ok, _} ->
        {:noreply, assign(socket, schema_valid: true, schema_error: nil)}
      {:error, msg} ->
        {:noreply, assign(socket, schema_valid: false, schema_error: msg)}
    end
  end

  # Save section
  def handle_event("save_section", %{"section" => params}, socket) do
    section = socket.assigns.selected_section

    case Reports.update_section_config(section, params) do
      {:ok, updated} ->
        sections = update_section_in_list(socket.assigns.sections, updated)
        {:noreply,
         socket
         |> put_flash(:info, "Section configuration saved.")
         |> assign(:sections, sections)
         |> assign(:selected_section, updated)
         |> assign(:section_form, section_form(updated))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save configuration.")
         |> assign(:section_form, to_form(changeset, as: :section))}
    end
  end
end
```

### Sub-Components

**Range Slider with Value Display:**
```heex
<div class="space-y-1">
  <div class="flex justify-between">
    <label class="label text-sm">{@label}</label>
    <span class="text-sm font-mono text-slate-600">{@value}</span>
  </div>
  <input
    type="range"
    name={@name}
    value={@value}
    min={@min}
    max={@max}
    step={@step}
    class="range range-sm range-primary w-full"
    phx-change="update_field"
  />
  <div class="flex justify-between text-xs text-slate-400">
    <span>{@min}</span>
    <span>{@max}</span>
  </div>
</div>
```

**Model Selector (Cascading):**
```heex
<div class="grid gap-4 md:grid-cols-2">
  <.input
    type="select"
    field={@form[:provider]}
    label="Provider"
    options={[{"Google (Gemini)", "google"}, {"Anthropic", "anthropic"}]}
    phx-change="provider_changed"
  />
  <.input
    type="select"
    field={@form[:model]}
    label="Model"
    options={models_for_provider(@selected_provider)}
  />
</div>
```

**JSON Editor with Validation:**
```heex
<div class="space-y-2">
  <div class="flex justify-between items-center">
    <label class="label text-sm">Output Schema (JSON)</label>
    <.schema_status valid={@schema_valid} />
  </div>
  <textarea
    name="section[output_schema_json]"
    phx-change="validate_schema"
    phx-debounce="500"
    class={[
      "textarea font-mono text-sm w-full h-80",
      @schema_error && "border-error",
      @schema_valid && "border-success"
    ]}
  >{format_schema(@section.output_schema)}</textarea>
  <.schema_error :if={@schema_error} message={@schema_error} />
</div>
```

### Model Options

```elixir
def models_for_provider("google") do
  [
    {"Gemini 2.0 Flash", "gemini-2.0-flash"},
    {"Gemini 2.0 Flash Lite", "gemini-2.0-flash-lite"},
    {"Gemini 1.5 Pro", "gemini-1.5-pro"},
    {"Gemini 1.5 Flash", "gemini-1.5-flash"}
  ]
end

def models_for_provider("anthropic") do
  [
    {"Claude 3.5 Sonnet", "claude-3-5-sonnet"},
    {"Claude 3 Haiku", "claude-3-haiku"}
  ]
end
```

### Route Configuration

```elixir
# router.ex
scope "/admin", LumainusWeb.Admin do
  pipe_through [:browser, :require_authenticated_user, :require_admin]

  live "/llm-config", LlmConfigLive, :index
end
```

## Consequences

### Positive
- All LLM parameters accessible in one place
- Logical tab organization prevents overwhelm
- Live validation prevents bad saves
- Familiar patterns from existing admin pages
- Responsive grid works on smaller screens

### Negative
- Significantly more complex than current page
- Many form fields to manage state for
- Tab switching adds complexity

### Design Principles
- **Utilitarian**: Focus on function over decoration
- **Cohesive**: Match existing admin page patterns
- **Progressive**: Simple tabs first, advanced last
- **Defensive**: Validate before allowing save
