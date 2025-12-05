defmodule LumainusWeb.Admin.LlmConfigLive do
  @moduledoc """
  Admin interface for configuring LLM settings per report section.

  This is the comprehensive "LLM Config Studio" that replaces the simpler /prompts page.
  It provides tabbed access to all configurable LLM parameters:

  - **Prompts**: System prompt, user prompt template
  - **Model**: Provider, model, fallback provider/model
  - **Generation**: Temperature, top_p, top_k, candidate_count, max_output_tokens
  - **Output**: Output schema (JSON), response MIME type
  - **Advanced**: Stop sequences, penalties, seed, timeout, retries, auto_run
  """

  use LumainusWeb, :live_view

  alias Lumainus.Reports
  alias Lumainus.Reports.{CacheSetting, CacheSettings, SchemaValidator}

  @tabs ["prompts", "model", "generation", "output", "advanced"]

  @providers [
    {"Google (Gemini)", "google"},
    {"Anthropic", "anthropic"}
  ]

  @models_by_provider %{
    "google" => [
      {"Gemini 2.0 Flash", "gemini-2.0-flash"},
      {"Gemini 2.0 Flash Lite", "gemini-2.0-flash-lite"},
      {"Gemini 1.5 Pro", "gemini-1.5-pro"},
      {"Gemini 1.5 Flash", "gemini-1.5-flash"},
      {"Gemini Flash Lite (Latest)", "gemini-flash-lite-latest"}
    ],
    "anthropic" => [
      {"Claude 3.5 Sonnet", "claude-3-5-sonnet"},
      {"Claude 3 Haiku", "claude-3-haiku"}
    ]
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    template = Reports.default_template_for_scope(scope)
    sections = template.sections
    selected = List.first(sections)

    # Load cache settings
    {:ok, cache_settings} = CacheSettings.fetch_or_init()

    {:ok,
     socket
     |> assign(:template, template)
     |> assign(:sections, sections)
     |> assign(:selected_section, selected)
     |> assign(:active_tab, "prompts")
     |> assign(:section_form, section_form(selected))
     |> assign(:template_form, template_form(template))
     |> assign(:cache_settings, cache_settings)
     |> assign(:cache_form, cache_form(cache_settings))
     |> assign(:cache_models, cache_model_options())
     |> assign(:schema_valid, validate_schema(selected))
     |> assign(:schema_error, nil)
     |> assign(:dirty, false)
     |> assign(:providers, @providers)
     |> assign(:models, models_for_provider(selected && selected.provider))}
  end

  @impl true
  def handle_event("select_section", %{"id" => id}, socket) do
    if socket.assigns.dirty do
      # Prompt user or auto-save - for now, just switch without saving
      do_select_section(socket, id)
    else
      do_select_section(socket, id)
    end
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in @tabs do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("validate_section", %{"section" => params}, socket) do
    # Mark form as dirty and validate schema if present
    socket =
      socket
      |> assign(:dirty, true)
      |> maybe_validate_schema(params)

    {:noreply, socket}
  end

  def handle_event("validate_schema", %{"schema_json" => json}, socket) do
    case SchemaValidator.validate_json(json) do
      {:ok, _} ->
        {:noreply, assign(socket, schema_error: nil, schema_valid: true)}

      {:error, msg} ->
        {:noreply, assign(socket, schema_error: msg, schema_valid: false)}
    end
  end

  def handle_event("provider_changed", %{"section" => %{"provider" => provider}}, socket) do
    models = models_for_provider(provider)
    default_model = models |> List.first() |> elem(1)

    # Update form with new provider and reset model to first in list
    section = socket.assigns.selected_section
    updated_form = section_form(%{section | provider: provider, model: default_model})

    {:noreply,
     socket
     |> assign(:models, models)
     |> assign(:section_form, updated_form)
     |> assign(:dirty, true)}
  end

  def handle_event("save_section", %{"section" => params}, socket) do
    section = socket.assigns.selected_section

    # Parse output_schema from JSON string if provided
    params = parse_schema_param(params)

    # Parse stop_sequences from comma-separated string
    params = parse_stop_sequences(params)

    case Reports.update_section_prompt(section, params) do
      {:ok, updated} ->
        sections = update_section_in_list(socket.assigns.sections, updated)

        {:noreply,
         socket
         |> put_flash(:info, "Section configuration saved.")
         |> assign(:sections, sections)
         |> assign(:selected_section, updated)
         |> assign(:section_form, section_form(updated))
         |> assign(:schema_valid, validate_schema(updated))
         |> assign(:schema_error, nil)
         |> assign(:dirty, false)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save configuration.")
         |> assign(:section_form, to_form(changeset, as: :section))}
    end
  end

  def handle_event("save_template", %{"template" => params}, socket) do
    template = socket.assigns.template

    case Reports.update_ingestion_prompt(template, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Template settings saved.")
         |> assign(:template, updated)
         |> assign(:template_form, template_form(updated))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save template settings.")
         |> assign(:template_form, to_form(changeset, as: :template))}
    end
  end

  def handle_event("save_cache_settings", %{"cache" => params}, socket) do
    case CacheSettings.update_settings(params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cache settings saved.")
         |> assign(:cache_settings, updated)
         |> assign(:cache_form, cache_form(updated))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save cache settings.")
         |> assign(:cache_form, to_form(changeset, as: :cache))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto py-8 px-6">
      <div class="mb-8">
        <p class="text-xs uppercase tracking-[0.3em] text-slate-400 font-semibold">Admin</p>
        <h1 class="text-3xl font-semibold text-slate-900 mt-2">
          LLM Config Studio
        </h1>
        <p class="text-slate-500 max-w-2xl">
          Configure prompts, models, and output schemas for report generation.
          Changes apply to the next report run.
        </p>
      </div>
      
    <!-- Cache Settings Card (Global) -->
      <.cache_settings_card form={@cache_form} settings={@cache_settings} models={@cache_models} />

      <div class="grid gap-6 lg:grid-cols-4 mt-6">
        <!-- Sidebar -->
        <div class="space-y-4">
          <.section_list sections={@sections} selected={@selected_section} />
          <.template_settings_card form={@template_form} template={@template} />
        </div>
        
    <!-- Main Panel -->
        <div class="lg:col-span-3">
          <.section_config_panel
            section={@selected_section}
            form={@section_form}
            active_tab={@active_tab}
            schema_valid={@schema_valid}
            schema_error={@schema_error}
            providers={@providers}
            models={@models}
            dirty={@dirty}
          />
        </div>
      </div>
    </div>
    """
  end

  # Components

  defp section_list(assigns) do
    ~H"""
    <div class="rounded-2xl border border-slate-200 bg-white">
      <div class="border-b border-slate-100 px-4 py-3">
        <p class="text-xs uppercase tracking-[0.2em] text-slate-400 font-semibold">
          Report Sections
        </p>
      </div>
      <div class="divide-y divide-slate-100 max-h-96 overflow-y-auto">
        <%= for section <- @sections do %>
          <button
            phx-click="select_section"
            phx-value-id={section.id}
            class={[
              "w-full text-left px-4 py-3 transition",
              @selected && @selected.id == section.id &&
                "bg-slate-50 text-slate-900 border-l-2 border-slate-400",
              @selected && @selected.id != section.id &&
                "hover:bg-slate-50 text-slate-600"
            ]}
          >
            <p class="text-sm font-semibold">{section.title}</p>
            <p class="text-xs text-slate-500 uppercase tracking-[0.2em]">
              {section.identifier}
            </p>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp template_settings_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-slate-200 bg-white p-5 space-y-3">
      <p class="text-sm font-semibold text-slate-900">Template Settings</p>

      <.form for={@form} phx-submit="save_template" class="space-y-4">
        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">
            System Prompt (Template Default)
          </label>
          <textarea
            name="template[system_prompt]"
            rows="4"
            class="textarea w-full rounded-lg border border-slate-200 p-2 text-sm font-mono"
            placeholder="Default system prompt for all sections..."
          >{@template.system_prompt}</textarea>
        </div>

        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">
            PDF Ingestion Prompt
          </label>
          <textarea
            name="template[ingestion_prompt_template]"
            rows="6"
            class="textarea w-full rounded-lg border border-slate-200 p-2 text-sm font-mono"
          >{@template.ingestion_prompt_template || Lumainus.Reports.ingestion_prompt(@template)}</textarea>
        </div>

        <div class="flex justify-end">
          <.button type="submit" class="btn btn-sm btn-primary">
            Save Template
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  defp cache_settings_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-indigo-200 bg-gradient-to-r from-indigo-50 to-white p-6">
      <div class="flex items-center gap-3 mb-4">
        <div class="p-2 bg-indigo-100 rounded-lg">
          <.icon name="hero-bolt" class="size-5 text-indigo-600" />
        </div>
        <div>
          <p class="text-lg font-semibold text-slate-900">Context Cache Settings</p>
          <p class="text-sm text-slate-500">
            Configure Gemini context caching for report generation
          </p>
        </div>
      </div>

      <.form for={@form} phx-submit="save_cache_settings" class="space-y-4">
        <div class="grid gap-4 md:grid-cols-3">
          <div>
            <label class="block text-xs font-medium text-slate-600 mb-1">Cache Model</label>
            <select
              name="cache[model]"
              class="select w-full rounded-lg border border-slate-200 text-sm"
            >
              <%= for {label, value} <- @models do %>
                <option value={value} selected={@settings.model == value}>{label}</option>
              <% end %>
            </select>
            <p class="text-xs text-slate-400 mt-1">Min tokens shown in dropdown</p>
          </div>

          <div>
            <label class="block text-xs font-medium text-slate-600 mb-1">TTL (seconds)</label>
            <input
              type="number"
              name="cache[ttl_seconds]"
              value={@settings.ttl_seconds}
              min="60"
              max="86400"
              class="input w-full rounded-lg border border-slate-200 text-sm"
            />
            <p class="text-xs text-slate-400 mt-1">1 min - 24 hours</p>
          </div>

          <div class="flex items-center pt-6">
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name="cache[enabled]"
                value="true"
                checked={@settings.enabled}
                class="checkbox checkbox-sm"
              />
              <span class="text-sm text-slate-700">Enable Caching</span>
            </label>
          </div>
        </div>

        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">
            Cache System Prompt
            <span class="text-slate-400 font-normal">(sent with cached document context)</span>
          </label>
          <textarea
            name="cache[system_prompt]"
            rows="3"
            class="textarea w-full rounded-lg border border-slate-200 p-3 text-sm font-mono"
            placeholder="System instructions for cached context..."
          >{@settings.system_prompt}</textarea>
        </div>

        <div class="flex justify-end">
          <.button type="submit" class="btn btn-sm btn-primary">
            Save Cache Settings
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  defp section_config_panel(assigns) do
    ~H"""
    <div class="rounded-2xl border border-slate-200 bg-white">
      <div class="border-b border-slate-100 px-6 py-4">
        <div class="flex justify-between items-center">
          <div>
            <h2 class="text-xl font-semibold text-slate-900">
              {@section && @section.title}
            </h2>
            <p class="text-sm text-slate-500">{@section && @section.identifier}</p>
          </div>
          <%= if @dirty do %>
            <span class="text-xs text-amber-600 font-medium">Unsaved changes</span>
          <% end %>
        </div>
      </div>
      
    <!-- Tabs -->
      <div class="border-b border-slate-100 px-6">
        <nav class="flex gap-6">
          <.tab_button tab="prompts" active={@active_tab} label="Prompts" />
          <.tab_button tab="model" active={@active_tab} label="Model" />
          <.tab_button tab="generation" active={@active_tab} label="Generation" />
          <.tab_button tab="output" active={@active_tab} label="Output" />
          <.tab_button tab="advanced" active={@active_tab} label="Advanced" />
        </nav>
      </div>
      
    <!-- Tab Content -->
      <.form for={@form} phx-submit="save_section" phx-change="validate_section" class="p-6 space-y-6">
        <%= case @active_tab do %>
          <% "prompts" -> %>
            <.prompts_tab form={@form} section={@section} />
          <% "model" -> %>
            <.model_tab form={@form} providers={@providers} models={@models} />
          <% "generation" -> %>
            <.generation_tab form={@form} />
          <% "output" -> %>
            <.output_tab
              form={@form}
              section={@section}
              schema_valid={@schema_valid}
              schema_error={@schema_error}
            />
          <% "advanced" -> %>
            <.advanced_tab form={@form} />
        <% end %>

        <div class="flex justify-end pt-4 border-t border-slate-100">
          <.button type="submit" class="btn btn-primary" disabled={@schema_valid == false}>
            Save Section
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  defp tab_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={[
        "py-3 text-sm font-medium border-b-2 transition",
        @active == @tab && "border-slate-900 text-slate-900",
        @active != @tab && "border-transparent text-slate-500 hover:text-slate-700"
      ]}
    >
      {@label}
    </button>
    """
  end

  defp prompts_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <label class="block text-sm font-medium text-slate-700 mb-2">
          System Prompt Override
          <span class="text-slate-400 font-normal">(leave empty to use template default)</span>
        </label>
        <textarea
          name="section[system_prompt]"
          rows="4"
          class="textarea w-full rounded-xl border border-slate-200 p-4 font-mono text-sm"
          placeholder="Override the template's system prompt for this section..."
        >{@section && @section.system_prompt}</textarea>
      </div>

      <div>
        <label class="block text-sm font-medium text-slate-700 mb-2">
          User Prompt Template <span class="text-red-500">*</span>
        </label>
        <textarea
          name="section[prompt_template]"
          rows="16"
          class="textarea w-full rounded-xl border border-slate-200 p-4 font-mono text-sm leading-relaxed"
          required
        >{@section && @section.prompt_template}</textarea>
        <p class="text-xs text-slate-500 mt-2">
          Supports EEx template syntax. Available variables: section_title, patient, documents, documents_summary, documents_text
        </p>
      </div>
    </div>
    """
  end

  defp model_tab(assigns) do
    ~H"""
    <div class="grid gap-6 md:grid-cols-2">
      <div>
        <label class="block text-sm font-medium text-slate-700 mb-2">Provider</label>
        <select
          name="section[provider]"
          class="select w-full rounded-lg border border-slate-200"
          phx-change="provider_changed"
        >
          <%= for {label, value} <- @providers do %>
            <option value={value} selected={@form[:provider].value == value}>{label}</option>
          <% end %>
        </select>
      </div>

      <div>
        <label class="block text-sm font-medium text-slate-700 mb-2">Model</label>
        <select name="section[model]" class="select w-full rounded-lg border border-slate-200">
          <%= for {label, value} <- @models do %>
            <option value={value} selected={@form[:model].value == value}>{label}</option>
          <% end %>
        </select>
      </div>

      <div>
        <label class="block text-sm font-medium text-slate-700 mb-2">
          Fallback Provider <span class="text-slate-400 font-normal">(optional)</span>
        </label>
        <select
          name="section[fallback_provider]"
          class="select w-full rounded-lg border border-slate-200"
        >
          <option value="">None</option>
          <%= for {label, value} <- @providers do %>
            <option value={value} selected={@form[:fallback_provider].value == value}>{label}</option>
          <% end %>
        </select>
      </div>

      <div>
        <label class="block text-sm font-medium text-slate-700 mb-2">
          Fallback Model <span class="text-slate-400 font-normal">(optional)</span>
        </label>
        <input
          type="text"
          name="section[fallback_model]"
          value={@form[:fallback_model].value}
          class="input w-full rounded-lg border border-slate-200"
          placeholder="e.g., gemini-1.5-pro"
        />
      </div>
    </div>
    """
  end

  defp generation_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="grid gap-6 md:grid-cols-2">
        <.range_input
          name="section[temperature]"
          label="Temperature"
          value={@form[:temperature].value || 0.2}
          min={0.0}
          max={2.0}
          step={0.1}
        />

        <.range_input
          name="section[top_p]"
          label="Top P"
          value={@form[:top_p].value || 0.95}
          min={0.0}
          max={1.0}
          step={0.05}
        />
      </div>

      <div class="grid gap-6 md:grid-cols-3">
        <div>
          <label class="block text-sm font-medium text-slate-700 mb-2">Top K</label>
          <input
            type="number"
            name="section[top_k]"
            value={@form[:top_k].value}
            min="0"
            class="input w-full rounded-lg border border-slate-200"
            placeholder="40"
          />
        </div>

        <div>
          <label class="block text-sm font-medium text-slate-700 mb-2">Candidate Count</label>
          <input
            type="number"
            name="section[candidate_count]"
            value={@form[:candidate_count].value || 1}
            min="1"
            class="input w-full rounded-lg border border-slate-200"
          />
        </div>

        <div>
          <label class="block text-sm font-medium text-slate-700 mb-2">Max Output Tokens</label>
          <input
            type="number"
            name="section[max_output_tokens]"
            value={@form[:max_output_tokens].value || 2048}
            min="1"
            class="input w-full rounded-lg border border-slate-200"
          />
        </div>
      </div>
    </div>
    """
  end

  defp output_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <div class="flex justify-between items-center mb-2">
          <label class="block text-sm font-medium text-slate-700">
            Output Schema (JSON)
          </label>
          <.schema_status valid={@schema_valid} />
        </div>
        <textarea
          name="section[output_schema_json]"
          phx-change="validate_schema"
          phx-debounce="500"
          rows="16"
          class={[
            "textarea font-mono text-sm w-full rounded-xl border p-4",
            @schema_error && "border-red-500",
            @schema_valid && "border-green-500",
            !@schema_error && !@schema_valid && "border-slate-200"
          ]}
        >{format_schema(@section && @section.output_schema)}</textarea>

        <%= if @schema_error do %>
          <p class="text-sm text-red-600 flex items-center gap-2 mt-2">
            <.icon name="hero-exclamation-circle" class="size-4" />
            {@schema_error}
          </p>
        <% end %>

        <%= if @schema_valid do %>
          <p class="text-sm text-green-600 flex items-center gap-2 mt-2">
            <.icon name="hero-check-circle" class="size-4" /> Schema is valid for Gemini API
          </p>
        <% end %>
      </div>

      <div>
        <label class="block text-sm font-medium text-slate-700 mb-2">
          Response MIME Type
        </label>
        <select
          name="section[response_mime_type]"
          class="select w-full rounded-lg border border-slate-200"
        >
          <option
            value="application/json"
            selected={@form[:response_mime_type].value == "application/json"}
          >
            application/json (for structured output)
          </option>
          <option value="text/plain" selected={@form[:response_mime_type].value == "text/plain"}>
            text/plain (for unstructured text)
          </option>
        </select>
        <p class="text-xs text-slate-500 mt-1">
          Note: When output schema is provided, application/json is always used.
        </p>
      </div>
    </div>
    """
  end

  defp advanced_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <label class="block text-sm font-medium text-slate-700 mb-2">
          Stop Sequences <span class="text-slate-400 font-normal">(comma-separated)</span>
        </label>
        <input
          type="text"
          name="section[stop_sequences_text]"
          value={format_stop_sequences(@form[:stop_sequences].value)}
          class="input w-full rounded-lg border border-slate-200"
          placeholder="e.g., END, STOP, ###"
        />
      </div>

      <div class="grid gap-6 md:grid-cols-2">
        <.range_input
          name="section[presence_penalty]"
          label="Presence Penalty"
          value={@form[:presence_penalty].value || 0.0}
          min={-2.0}
          max={2.0}
          step={0.1}
        />

        <.range_input
          name="section[frequency_penalty]"
          label="Frequency Penalty"
          value={@form[:frequency_penalty].value || 0.0}
          min={-2.0}
          max={2.0}
          step={0.1}
        />
      </div>

      <div class="grid gap-6 md:grid-cols-3">
        <div>
          <label class="block text-sm font-medium text-slate-700 mb-2">Seed</label>
          <input
            type="number"
            name="section[seed]"
            value={@form[:seed].value}
            class="input w-full rounded-lg border border-slate-200"
            placeholder="Optional"
          />
        </div>

        <div>
          <label class="block text-sm font-medium text-slate-700 mb-2">Timeout (ms)</label>
          <input
            type="number"
            name="section[timeout_ms]"
            value={@form[:timeout_ms].value || 120_000}
            min="1000"
            class="input w-full rounded-lg border border-slate-200"
          />
        </div>

        <div>
          <label class="block text-sm font-medium text-slate-700 mb-2">Max Retries</label>
          <input
            type="number"
            name="section[max_retries]"
            value={@form[:max_retries].value || 3}
            min="0"
            class="input w-full rounded-lg border border-slate-200"
          />
        </div>
      </div>

      <div class="grid gap-6 md:grid-cols-2">
        <div>
          <label class="block text-sm font-medium text-slate-700 mb-2">Retry Delay (ms)</label>
          <input
            type="number"
            name="section[retry_delay_ms]"
            value={@form[:retry_delay_ms].value || 1000}
            min="0"
            class="input w-full rounded-lg border border-slate-200"
          />
        </div>

        <div class="flex items-center pt-8">
          <label class="flex items-center gap-2 cursor-pointer">
            <input
              type="checkbox"
              name="section[auto_run]"
              checked={@form[:auto_run].value}
              class="checkbox"
            />
            <span class="text-sm text-slate-700">Auto-run this section when report starts</span>
          </label>
        </div>
      </div>
    </div>
    """
  end

  defp range_input(assigns) do
    assigns = assign_new(assigns, :value, fn -> 0 end)

    ~H"""
    <div class="space-y-1">
      <div class="flex justify-between">
        <label class="text-sm font-medium text-slate-700">{@label}</label>
        <span class="text-sm font-mono text-slate-600">{@value}</span>
      </div>
      <input
        type="range"
        name={@name}
        value={@value}
        min={@min}
        max={@max}
        step={@step}
        class="range range-sm w-full"
      />
      <div class="flex justify-between text-xs text-slate-400">
        <span>{@min}</span>
        <span>{@max}</span>
      </div>
    </div>
    """
  end

  defp schema_status(assigns) do
    ~H"""
    <%= if @valid do %>
      <span class="text-xs text-green-600 flex items-center gap-1">
        <.icon name="hero-check-circle" class="size-4" /> Valid
      </span>
    <% else %>
      <span class="text-xs text-red-600 flex items-center gap-1">
        <.icon name="hero-x-circle" class="size-4" /> Invalid
      </span>
    <% end %>
    """
  end

  # Helper functions

  defp do_select_section(socket, id) do
    section = Enum.find(socket.assigns.sections, &(&1.id == id))

    {:noreply,
     socket
     |> assign(:selected_section, section)
     |> assign(:section_form, section_form(section))
     |> assign(:active_tab, "prompts")
     |> assign(:schema_valid, validate_schema(section))
     |> assign(:schema_error, nil)
     |> assign(:dirty, false)
     |> assign(:models, models_for_provider(section && section.provider))}
  end

  defp section_form(nil), do: to_form(%{}, as: :section)

  defp section_form(section) do
    data = %{
      "prompt_template" => section.prompt_template,
      "system_prompt" => section.system_prompt,
      "provider" => section.provider || "google",
      "model" => section.model || "gemini-flash-lite-latest",
      "fallback_provider" => section.fallback_provider,
      "fallback_model" => section.fallback_model,
      "temperature" => section.temperature,
      "top_p" => section.top_p,
      "top_k" => section.top_k,
      "candidate_count" => section.candidate_count || 1,
      "max_output_tokens" => section.max_output_tokens,
      "stop_sequences" => section.stop_sequences || [],
      "presence_penalty" => section.presence_penalty,
      "frequency_penalty" => section.frequency_penalty,
      "seed" => section.seed,
      "timeout_ms" => section.timeout_ms || 120_000,
      "max_retries" => section.max_retries || 3,
      "retry_delay_ms" => section.retry_delay_ms || 1000,
      "response_mime_type" => section.response_mime_type || "application/json",
      "auto_run" => section.auto_run
    }

    to_form(data, as: :section)
  end

  defp template_form(template) do
    data = %{
      "ingestion_prompt_template" => template.ingestion_prompt_template,
      "system_prompt" => template.system_prompt
    }

    to_form(data, as: :template)
  end

  defp models_for_provider(nil), do: @models_by_provider["google"]
  defp models_for_provider(provider), do: Map.get(@models_by_provider, provider, [])

  defp validate_schema(nil), do: true

  defp validate_schema(section) do
    case section.output_schema do
      nil -> true
      schema when map_size(schema) == 0 -> true
      schema -> SchemaValidator.valid?(schema)
    end
  end

  defp maybe_validate_schema(socket, %{"output_schema_json" => json}) when is_binary(json) do
    case SchemaValidator.validate_json(json) do
      {:ok, _} ->
        assign(socket, schema_error: nil, schema_valid: true)

      {:error, msg} ->
        assign(socket, schema_error: msg, schema_valid: false)
    end
  end

  defp maybe_validate_schema(socket, _params), do: socket

  defp parse_schema_param(%{"output_schema_json" => json} = params) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, schema} ->
        params
        |> Map.delete("output_schema_json")
        |> Map.put("output_schema", schema)

      {:error, _} ->
        # Keep the raw JSON, let changeset validation catch it
        Map.delete(params, "output_schema_json")
    end
  end

  defp parse_schema_param(params), do: params

  defp parse_stop_sequences(%{"stop_sequences_text" => text} = params) when is_binary(text) do
    sequences =
      text
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    params
    |> Map.delete("stop_sequences_text")
    |> Map.put("stop_sequences", sequences)
  end

  defp parse_stop_sequences(params), do: params

  defp format_schema(nil), do: ""
  defp format_schema(schema) when map_size(schema) == 0, do: ""

  defp format_schema(schema) do
    Jason.encode!(schema, pretty: true)
  end

  defp format_stop_sequences(nil), do: ""
  defp format_stop_sequences([]), do: ""
  defp format_stop_sequences(sequences) when is_list(sequences), do: Enum.join(sequences, ", ")
  defp format_stop_sequences(_), do: ""

  defp update_section_in_list(sections, updated) do
    Enum.map(sections, fn section ->
      if section.id == updated.id, do: updated, else: section
    end)
  end

  defp cache_form(settings) do
    data = %{
      "system_prompt" => settings.system_prompt,
      "model" => settings.model,
      "ttl_seconds" => settings.ttl_seconds,
      "enabled" => settings.enabled
    }

    to_form(data, as: :cache)
  end

  defp cache_model_options do
    # Get models from the schema - no hardcoded labels
    # Display model name directly, with min tokens info
    CacheSetting.cache_models()
    |> Enum.map(fn {model, %{min_tokens: min}} ->
      {"#{model} (min #{min} tokens)", model}
    end)
    |> Enum.sort_by(fn {_, model} -> model end)
  end
end
