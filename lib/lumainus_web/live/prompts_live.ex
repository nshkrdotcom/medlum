defmodule LumainusWeb.PromptsLive do
  use LumainusWeb, :live_view

  alias Lumainus.Reports

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    template = Reports.default_template_for_scope(scope)
    sections = template.sections
    selected_section = List.first(sections)

    {:ok,
     socket
     |> assign(:template, template)
     |> assign(:sections, sections)
     |> assign(:selected_section, selected_section)
     |> assign(:section_form, section_form(selected_section))
     |> assign(:ingestion_form, ingestion_form(template))}
  end

  @impl true
  def handle_event("select_section", %{"id" => id}, socket) do
    section =
      Enum.find(socket.assigns.sections, fn section ->
        section.id == id
      end)

    {:noreply,
     socket
     |> assign(:selected_section, section)
     |> assign(:section_form, section_form(section))}
  end

  def handle_event("save_section_prompt", %{"section" => params}, socket) do
    section = socket.assigns.selected_section

    case Reports.update_section_prompt(section, params) do
      {:ok, updated} ->
        sections =
          Enum.map(socket.assigns.sections, fn s ->
            if s.id == updated.id, do: updated, else: s
          end)

        {:noreply,
         socket
         |> put_flash(:info, "Section prompt updated.")
         |> assign(:sections, sections)
         |> assign(:selected_section, updated)
         |> assign(:section_form, section_form(updated))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to update prompt.")
         |> assign(:section_form, to_form(changeset, as: :section))}
    end
  end

  def handle_event("save_ingestion_prompt", %{"template" => params}, socket) do
    template = socket.assigns.template

    case Reports.update_ingestion_prompt(template, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ingestion prompt updated.")
         |> assign(:template, updated)
         |> assign(:ingestion_form, ingestion_form(updated))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to update ingestion prompt.")
         |> assign(:ingestion_form, to_form(changeset, as: :template))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto py-10 px-6 space-y-8">
      <div>
        <p class="text-xs uppercase tracking-[0.3em] text-slate-400 font-semibold">Prompt Studio</p>
        <h1 class="text-3xl font-semibold text-slate-900 mt-2">
          Report Templates
        </h1>
        <p class="text-slate-500 max-w-2xl">
          Tune the LLM prompts that generate each section of the report and the PDF ingestion pipeline. Changes apply instantly to the next run.
        </p>
      </div>

      <div class="grid gap-6 lg:grid-cols-3">
        <div class="space-y-4">
          <div class="rounded-2xl border border-slate-200 bg-white">
            <div class="border-b border-slate-100 px-4 py-3">
              <p class="text-xs uppercase tracking-[0.2em] text-slate-400 font-semibold">
                Report Sections
              </p>
            </div>
            <div class="divide-y divide-slate-100">
              <%= for section <- @sections do %>
                <button
                  phx-click="select_section"
                  phx-value-id={section.id}
                  class={[
                    "w-full text-left px-4 py-3 transition",
                    @selected_section && @selected_section.id == section.id &&
                      "bg-slate-50 text-slate-900 border-l-2 border-slate-400",
                    @selected_section && @selected_section.id != section.id &&
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

          <div class="rounded-2xl border border-slate-200 bg-white p-5 space-y-3">
            <p class="text-sm font-semibold text-slate-900">PDF Ingestion Prompt</p>
            <p class="text-sm text-slate-500">
              Controls how uploaded PDFs are converted into normalized markdown before running reports.
            </p>
            <.form for={@ingestion_form} phx-submit="save_ingestion_prompt">
              <.input
                type="textarea"
                field={@ingestion_form[:ingestion_prompt_template]}
                rows="10"
                class="w-full rounded-xl border border-slate-200 p-3 text-sm font-mono"
              />
              <div class="flex justify-end">
                <.button type="submit" class="btn btn-primary btn-sm">
                  Save ingestion prompt
                </.button>
              </div>
            </.form>
          </div>
        </div>

        <div class="lg:col-span-2">
          <div class="rounded-2xl border border-slate-200 bg-white p-6 space-y-4">
            <div>
              <p class="text-xs uppercase tracking-[0.3em] text-slate-400 font-semibold">
                Editing
              </p>
              <h2 class="text-2xl font-semibold text-slate-900 mt-1">
                {@selected_section && @selected_section.title}
              </h2>
            </div>

            <.form for={@section_form} phx-submit="save_section_prompt">
              <.input
                type="textarea"
                field={@section_form[:prompt_template]}
                rows="20"
                class="w-full rounded-2xl border border-slate-200 p-4 font-mono text-sm leading-relaxed"
              />
              <div class="flex justify-end">
                <.button type="submit" class="btn btn-primary">
                  Save section prompt
                </.button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp section_form(nil), do: to_form(%{"prompt_template" => ""}, as: :section)

  defp section_form(section) do
    data = %{"prompt_template" => section && section.prompt_template}
    to_form(data, as: :section)
  end

  defp ingestion_form(template) do
    data = %{
      "ingestion_prompt_template" =>
        template.ingestion_prompt_template || Reports.ingestion_prompt(template)
    }

    to_form(data, as: :template)
  end
end
