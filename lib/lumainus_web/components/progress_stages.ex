defmodule LumainusWeb.Components.ProgressStages do
  @moduledoc """
  Multi-stage progress indicator for document ingestion.

  Displays a 6-stage progress bar with individual stage indicators:
  1. Upload & Prepare
  2. OCR Processing
  3. Layout Analysis
  4. Table Extraction
  5. Assembly
  6. Persist & Index
  """
  use Phoenix.Component

  @stages [
    {1, "Upload", "hero-arrow-up-tray"},
    {2, "OCR", "hero-document-text"},
    {3, "Layout", "hero-squares-2x2"},
    {4, "Tables", "hero-table-cells"},
    {5, "Build", "hero-puzzle-piece"},
    {6, "Save", "hero-cloud-arrow-up"}
  ]

  @doc """
  Renders a multi-stage progress indicator.

  ## Examples

      <.progress_stages progress={@upload.metadata["progress"]} />

  ## Attributes

    * `progress` - Map containing progress data:
      * `"overall"` - Overall percentage (0-100)
      * `"stage"` - Current stage number (1-6)
      * `"stage_name"` - Human-readable stage name
      * `"pages_done"` - Pages processed
      * `"pages_total"` - Total pages
      * `"stages"` - Map of stage data

    * `class` - Additional CSS classes
    * `compact` - Use compact layout (default: false)
  """
  attr :progress, :map, default: %{}
  attr :class, :string, default: ""
  attr :compact, :boolean, default: false

  def progress_stages(assigns) do
    assigns = assign(assigns, :stages_config, @stages)

    ~H"""
    <div class={["space-y-3", @class]}>
      <!-- Overall progress bar -->
      <div class="flex items-center gap-3">
        <div class="flex-1 bg-base-200 rounded-full h-2.5 overflow-hidden">
          <div
            class="bg-primary h-full transition-all duration-500 ease-out"
            style={"width: #{@progress["overall"] || 0}%"}
          />
        </div>
        <span class="text-sm font-mono font-medium w-10 text-right tabular-nums">
          {@progress["overall"] || 0}%
        </span>
      </div>
      
    <!-- Stage indicators -->
      <div class="flex justify-between px-1">
        <%= for {num, name, icon} <- @stages_config do %>
          <% stage_data = get_in(@progress, ["stages", to_string(num)]) || %{} %>
          <% status = stage_data["status"] || "pending" %>
          <% is_current = @progress["stage"] == num %>
          <.stage_indicator
            number={num}
            name={name}
            icon={icon}
            status={status}
            progress={stage_data["progress"] || 0}
            current={is_current}
            compact={@compact}
          />
        <% end %>
      </div>
      
    <!-- Current stage details -->
      <%= if @progress["stage"] && not @compact do %>
        <div class="text-sm text-base-content/70 text-center">
          <span class="font-medium">{@progress["stage_name"] || "Processing"}</span>
          <%= if @progress["pages_total"] && @progress["pages_total"] > 0 do %>
            <span class="text-base-content/50 ml-1">
              ({@progress["pages_done"] || 0}/{@progress["pages_total"]} pages)
            </span>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :number, :integer, required: true
  attr :name, :string, required: true
  attr :icon, :string, required: true
  attr :status, :string, required: true
  attr :progress, :integer, required: true
  attr :current, :boolean, default: false
  attr :compact, :boolean, default: false

  defp stage_indicator(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-1">
      <div class={[
        "rounded-full flex items-center justify-center transition-all duration-300",
        if(@compact, do: "w-7 h-7", else: "w-9 h-9"),
        stage_classes(@status, @current)
      ]}>
        <%= if @status == "completed" do %>
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 20 20"
            fill="currentColor"
            class={if(@compact, do: "w-3.5 h-3.5", else: "w-4 h-4")}
          >
            <path
              fill-rule="evenodd"
              d="M16.704 4.153a.75.75 0 01.143 1.052l-8 10.5a.75.75 0 01-1.127.075l-4.5-4.5a.75.75 0 011.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 011.05-.143z"
              clip-rule="evenodd"
            />
          </svg>
        <% else %>
          <span class={[
            "font-semibold",
            if(@compact, do: "text-xs", else: "text-sm")
          ]}>
            {@number}
          </span>
        <% end %>
      </div>
      <%= unless @compact do %>
        <span class={[
          "text-xs whitespace-nowrap",
          if(@current, do: "font-semibold text-primary", else: "text-base-content/60")
        ]}>
          {@name}
        </span>
      <% end %>
    </div>
    """
  end

  defp stage_classes("completed", _), do: "bg-success text-success-content"
  defp stage_classes("in_progress", true), do: "bg-primary text-primary-content animate-pulse"
  defp stage_classes("in_progress", false), do: "bg-primary/60 text-primary-content"
  defp stage_classes(_, _), do: "bg-base-300 text-base-content/40"

  @doc """
  Returns the default progress map for initial state.
  """
  def default_progress do
    %{
      "overall" => 0,
      "stage" => 1,
      "stage_name" => "Upload & Prepare",
      "stage_progress" => 0,
      "pages_done" => 0,
      "pages_total" => 0,
      "stages" => %{
        "1" => %{"status" => "in_progress", "progress" => 0},
        "2" => %{"status" => "pending", "progress" => 0},
        "3" => %{"status" => "pending", "progress" => 0},
        "4" => %{"status" => "pending", "progress" => 0},
        "5" => %{"status" => "pending", "progress" => 0},
        "6" => %{"status" => "pending", "progress" => 0}
      }
    }
  end
end
