# Multi-Stage Progress UI Design

## Overview

This document describes the design for a comprehensive multi-stage progress indicator that displays document ingestion progress in the Phoenix UI, integrating Docling's detailed telemetry into a user-friendly staged progress display.

---

## Stage Architecture

### Stage Breakdown

| Stage | Name | Weight | Description |
|-------|------|--------|-------------|
| 1 | **Upload & Prepare** | 5% | File upload, validation, queue submission |
| 2 | **OCR Processing** | 25% | Text extraction from images/scanned pages |
| 3 | **Layout Analysis** | 25% | Document structure detection (headers, paragraphs, etc.) |
| 4 | **Table Extraction** | 20% | Table structure recognition and cell extraction |
| 5 | **Assembly** | 15% | Page assembly and reading order determination |
| 6 | **Persist & Index** | 10% | Save to database, create chunks, index |

**Total: 100%**

### Stage Mapping from Docling Events

```
Phoenix Stages          Docling Pipeline Stages
─────────────────       ───────────────────────
1. Upload & Prepare  →  downloading, docling (initial)
2. OCR Processing    →  stage_batch_complete (stage: "ocr")
3. Layout Analysis   →  stage_batch_complete (stage: "layout")
4. Table Extraction  →  stage_batch_complete (stage: "table")
5. Assembly          →  stage_batch_complete (stage: "assemble") + page_processed
6. Persist & Index   →  parsing, completed
```

---

## Progress Calculation

### Formula

```
overall_progress = stage_base + (stage_weight × stage_internal_progress)
```

Where:
- `stage_base` = sum of weights of completed stages
- `stage_weight` = weight of current stage (as decimal)
- `stage_internal_progress` = 0-100% within current stage

### Stage Internal Progress

For Docling stages (2-5), internal progress is calculated from page completion:

```
stage_internal_progress = (pages_processed_in_stage / total_pages) × 100
```

**Note**: Stages run in parallel in the threaded pipeline, so we track the "slowest" stage (typically layout or table) as the bottleneck.

### Example Calculation

For a 764-page document at page 382 (50% through Docling):

```
Stage 2 (OCR):     5% + (25% × 100%) = 30%    [completed]
Stage 3 (Layout):  30% + (25% × 50%) = 42.5%  [in progress - bottleneck]
Stage 4 (Table):   waiting on layout
Stage 5 (Assembly): waiting on table

Overall Progress: 42% (rounded)
```

---

## Data Model

### IngestionProgress Schema

Add to `document_uploads.metadata`:

```elixir
%{
  "progress" => %{
    "overall" => 42,           # 0-100 integer
    "stage" => 3,              # Current stage number (1-6)
    "stage_name" => "layout",  # Human-readable stage name
    "stage_progress" => 50,    # 0-100 within stage
    "pages_done" => 382,
    "pages_total" => 764,
    "stages" => %{
      "1" => %{"status" => "completed", "progress" => 100},
      "2" => %{"status" => "completed", "progress" => 100},
      "3" => %{"status" => "in_progress", "progress" => 50},
      "4" => %{"status" => "pending", "progress" => 0},
      "5" => %{"status" => "pending", "progress" => 0},
      "6" => %{"status" => "pending", "progress" => 0}
    }
  }
}
```

### Event Payload Enhancement

Update `_docling_progress_cb` in `docling_service/app/main.py` to include stage info:

```python
{
    "type": "stage_batch_complete",
    "stage": "ocr",
    "batch_size": 4,
    "elapsed_ms": 450,
    "pages_done": 48,
    "pages_total": 764,
    "message": "Stage ocr processed 4 items in 450ms"
}
```

---

## Debouncing Strategy

### Integer Percentage Debouncing

Only emit UI updates when the **integer percentage changes**:

```elixir
defp should_emit_progress?(old_progress, new_progress) do
  trunc(old_progress) != trunc(new_progress)
end
```

This limits updates to **maximum 101 events** (0%, 1%, 2%, ... 100%) regardless of document size.

### Stage Tracking Debouncing

Track per-stage progress to avoid redundant updates:

```elixir
defmodule Medlum.Documents.ProgressTracker do
  @stage_weights %{
    1 => 0.05,   # Upload & Prepare
    2 => 0.25,   # OCR
    3 => 0.25,   # Layout
    4 => 0.20,   # Table
    5 => 0.15,   # Assembly
    6 => 0.10    # Persist
  }

  def calculate_overall_progress(stage_progress_map) do
    Enum.reduce(@stage_weights, 0, fn {stage, weight}, acc ->
      stage_pct = Map.get(stage_progress_map, stage, 0) / 100
      acc + (weight * stage_pct * 100)
    end)
    |> trunc()
  end

  def should_emit?(state, new_overall) do
    old_overall = state[:last_emitted_progress] || 0
    trunc(new_overall) > trunc(old_overall)
  end
end
```

---

## Phoenix Integration

### IngestionProcessor Updates

Modify `lib/medlum/documents/ingestion_processor.ex`:

```elixir
defp maybe_track_progress(job, %{"state" => "running"} = status) do
  event_type = Map.get(status, "type")
  stage = Map.get(status, "stage")
  pages_done = Map.get(status, "pages_done", 0)
  pages_total = Map.get(status, "pages_total", 1)

  # Map Docling stage to our stage number
  stage_num = docling_stage_to_number(stage, event_type)

  # Calculate stage internal progress
  stage_internal = if pages_total > 0 do
    (pages_done / pages_total) * 100
  else
    0
  end

  # Update stage progress map
  state_key = {:progress_state, job.id}
  state = Process.get(state_key, initial_progress_state())

  updated_stages = Map.update(
    state.stages,
    stage_num,
    %{progress: stage_internal, status: "in_progress"},
    fn s -> %{s | progress: max(s.progress, stage_internal)} end
  )

  # Calculate overall progress
  overall = ProgressTracker.calculate_overall_progress(updated_stages)

  # Only emit if integer percentage changed
  if ProgressTracker.should_emit?(state, overall) do
    Documents.record_job_stage!(job, "docling",
      progress: overall,
      message: stage_message(stage_num, pages_done, pages_total),
      payload: %{
        stage: stage_num,
        stage_name: stage_name(stage_num),
        stage_progress: trunc(stage_internal),
        pages_done: pages_done,
        pages_total: pages_total,
        stages: format_stages(updated_stages)
      },
      upload_status: "processing",
      broadcast: true  # Enable for LiveView updates
    )

    Process.put(state_key, %{
      state |
      stages: updated_stages,
      last_emitted_progress: overall
    })
  else
    Process.put(state_key, %{state | stages: updated_stages})
  end
end

defp docling_stage_to_number("preprocess", _), do: 2
defp docling_stage_to_number("ocr", _), do: 2
defp docling_stage_to_number("layout", _), do: 3
defp docling_stage_to_number("table", _), do: 4
defp docling_stage_to_number("assemble", _), do: 5
defp docling_stage_to_number(_, "page_processed"), do: 5
defp docling_stage_to_number(_, _), do: 2

defp stage_name(1), do: "Upload & Prepare"
defp stage_name(2), do: "OCR Processing"
defp stage_name(3), do: "Layout Analysis"
defp stage_name(4), do: "Table Extraction"
defp stage_name(5), do: "Assembly"
defp stage_name(6), do: "Persist & Index"

defp initial_progress_state do
  %{
    stages: %{
      1 => %{progress: 100, status: "completed"},
      2 => %{progress: 0, status: "pending"},
      3 => %{progress: 0, status: "pending"},
      4 => %{progress: 0, status: "pending"},
      5 => %{progress: 0, status: "pending"},
      6 => %{progress: 0, status: "pending"}
    },
    last_emitted_progress: 5
  }
end
```

### LiveView Component

Create `lib/medlum_web/components/progress_stages.ex`:

```elixir
defmodule MedlumWeb.Components.ProgressStages do
  use Phoenix.Component

  @stages [
    {1, "Upload", "hero-arrow-up-tray"},
    {2, "OCR", "hero-document-text"},
    {3, "Layout", "hero-squares-2x2"},
    {4, "Tables", "hero-table-cells"},
    {5, "Assembly", "hero-puzzle-piece"},
    {6, "Save", "hero-cloud-arrow-up"}
  ]

  attr :progress, :map, required: true
  attr :class, :string, default: ""

  def progress_stages(assigns) do
    assigns = assign(assigns, :stages, @stages)

    ~H"""
    <div class={["space-y-3", @class]}>
      <!-- Overall progress bar -->
      <div class="flex items-center gap-3">
        <div class="flex-1 bg-base-200 rounded-full h-3 overflow-hidden">
          <div
            class="bg-primary h-full transition-all duration-300 ease-out"
            style={"width: #{@progress["overall"] || 0}%"}
          />
        </div>
        <span class="text-sm font-medium w-12 text-right">
          <%= @progress["overall"] || 0 %>%
        </span>
      </div>

      <!-- Stage indicators -->
      <div class="flex justify-between">
        <%= for {num, name, icon} <- @stages do %>
          <% stage_data = get_in(@progress, ["stages", to_string(num)]) || %{} %>
          <% status = stage_data["status"] || "pending" %>
          <.stage_indicator
            number={num}
            name={name}
            icon={icon}
            status={status}
            progress={stage_data["progress"] || 0}
            current={@progress["stage"] == num}
          />
        <% end %>
      </div>

      <!-- Current stage details -->
      <%= if @progress["stage"] do %>
        <div class="text-sm text-base-content/70 text-center">
          Stage <%= @progress["stage"] %> of 6: <%= @progress["stage_name"] %>
          <%= if @progress["pages_total"] do %>
            (<%= @progress["pages_done"] %>/<%= @progress["pages_total"] %> pages)
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

  defp stage_indicator(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-1">
      <div class={[
        "w-10 h-10 rounded-full flex items-center justify-center transition-all",
        stage_classes(@status, @current)
      ]}>
        <%= if @status == "completed" do %>
          <.icon name="hero-check" class="w-5 h-5" />
        <% else %>
          <.icon name={@icon} class="w-5 h-5" />
        <% end %>
      </div>
      <span class={[
        "text-xs",
        if(@current, do: "font-semibold", else: "text-base-content/60")
      ]}>
        <%= @name %>
      </span>
    </div>
    """
  end

  defp stage_classes("completed", _), do: "bg-success text-success-content"
  defp stage_classes("in_progress", true), do: "bg-primary text-primary-content animate-pulse"
  defp stage_classes("in_progress", false), do: "bg-primary/50 text-primary-content"
  defp stage_classes(_, _), do: "bg-base-200 text-base-content/40"
end
```

### Usage in ReportsLive

Update `lib/medlum_web/live/reports_live.ex`:

```elixir
defmodule MedlumWeb.ReportsLive do
  use MedlumWeb, :live_view
  import MedlumWeb.Components.ProgressStages

  # ... existing code ...

  def render(assigns) do
    ~H"""
    <div>
      <!-- Existing UI -->

      <!-- Progress for uploading documents -->
      <%= for upload <- @uploads do %>
        <%= if upload.status == "processing" do %>
          <div class="card bg-base-100 shadow-sm p-4 mb-4">
            <h3 class="font-medium mb-2"><%= upload.filename %></h3>
            <.progress_stages progress={upload.metadata["progress"] || default_progress()} />
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp default_progress do
    %{
      "overall" => 0,
      "stage" => 1,
      "stage_name" => "Upload & Prepare",
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
```

---

## PubSub Integration

### Broadcasting Updates

In `lib/medlum/documents.ex`, ensure progress updates broadcast:

```elixir
defp notify_job_progress(job, event) do
  Phoenix.PubSub.broadcast(
    Medlum.PubSub,
    "ingestion:#{job.upload.tenant_id}",
    {:ingestion_progress, %{
      upload_id: job.upload.id,
      job_id: job.id,
      progress: event.payload,
      message: event.message
    }}
  )
end
```

### LiveView Subscription

```elixir
def mount(_params, session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(
      Medlum.PubSub,
      "ingestion:#{socket.assigns.current_tenant.id}"
    )
  end

  {:ok, socket}
end

def handle_info({:ingestion_progress, data}, socket) do
  # Update the relevant upload in assigns
  socket = update_upload_progress(socket, data.upload_id, data.progress)
  {:noreply, socket}
end
```

---

## Bottleneck Tracking

Since Docling's pipeline stages run in parallel, we need to track the slowest stage as the bottleneck:

```elixir
defp calculate_bottleneck_progress(stages) do
  # The overall progress is limited by the slowest stage
  # Stages must complete in order: OCR -> Layout -> Table -> Assembly

  stage_order = [2, 3, 4, 5]

  Enum.reduce_while(stage_order, 100, fn stage_num, _acc ->
    stage = Map.get(stages, stage_num, %{progress: 0})

    if stage.progress < 100 do
      {:halt, stage.progress}
    else
      {:cont, 100}
    end
  end)
end
```

---

## Timeline Estimation (Optional)

Based on observed processing rates:

```elixir
defmodule Medlum.Documents.ProgressEstimator do
  @avg_page_time_ms 500  # Average time per page in ms

  def estimate_remaining(pages_done, pages_total, elapsed_ms) do
    if pages_done > 0 do
      avg_per_page = elapsed_ms / pages_done
      remaining_pages = pages_total - pages_done
      remaining_ms = remaining_pages * avg_per_page

      format_duration(remaining_ms)
    else
      "Calculating..."
    end
  end

  defp format_duration(ms) when ms < 60_000, do: "< 1 min"
  defp format_duration(ms) when ms < 3_600_000 do
    mins = trunc(ms / 60_000)
    "~#{mins} min"
  end
  defp format_duration(ms) do
    hours = trunc(ms / 3_600_000)
    mins = trunc(rem(ms, 3_600_000) / 60_000)
    "~#{hours}h #{mins}m"
  end
end
```

---

## Implementation Checklist

### Phase 1: Backend (This Document)
- [ ] Update `IngestionProcessor` with stage mapping
- [ ] Add `ProgressTracker` module
- [ ] Update event payload structure
- [ ] Implement integer percentage debouncing

### Phase 2: Frontend
- [ ] Create `ProgressStages` component
- [ ] Add PubSub subscription to LiveView
- [ ] Update `ReportsLive` to display progress
- [ ] Add animations and transitions

### Phase 3: Polish
- [ ] Add time estimation
- [ ] Add error state handling
- [ ] Add retry UI
- [ ] Test with various document sizes

---

## Testing

### Test Cases

1. **Small document (1-10 pages)**: Should complete quickly, stages may overlap
2. **Medium document (50-100 pages)**: Normal progression through stages
3. **Large document (500+ pages)**: Extended processing, test debouncing
4. **Timeout scenario**: Verify partial progress is preserved
5. **Error scenario**: Verify stage shows failed state

### Performance Targets

- UI updates: Max 101 (one per integer percentage)
- DB writes: Max 21 (one per 5% increment)
- Perceived smoothness: Updates every 1-2 seconds for large docs

---

## Appendix: Event Type Reference

### Docling Events

| Event Type | Stage | Description |
|------------|-------|-------------|
| `docling_started` | 2 | Conversion begins |
| `stage_batch_complete` | 2-5 | Batch processed (with stage name) |
| `page_processed` | 5 | Single page fully processed |
| `page_failed` | - | Page failed processing |
| `docling_completed` | 5 | All pages done |
| `docling_timeout` | - | Processing timeout |

### Phoenix Stages

| Event Type | Stage | Description |
|------------|-------|-------------|
| `downloading` | 1 | Preparing upload |
| `docling` | 2-5 | Docling processing |
| `parsing` | 6 | Persisting results |
| `completed` | 6 | Ingestion complete |
| `failed` | - | Ingestion failed |
