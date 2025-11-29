# New PDF Upload Page Specification

**Date:** November 28, 2025
**Goal:** Absolutely reliable, seamless PDF upload with zero user complexity

---

## Design Philosophy

> "Upload PDF, get result. Know nothing about GPUs, backends, or fallbacks."

The user should:
1. Drag & drop a PDF
2. See real-time progress
3. Get structured data when done
4. See clear errors if something fails

The user should NOT:
- Choose backends
- Know about Docker vs Cloud
- Wait 20 minutes wondering if it's broken
- Manually refresh to see status

---

## Page: `/upload` (New LiveView)

### File: `lib/lumainus_web/live/upload_live.ex`

```elixir
defmodule LumainusWeb.UploadLive do
  use LumainusWeb, :live_view
  alias Lumainus.Documents
  alias Lumainus.Backends.Router

  @max_file_size_mb 100
  @accepted_types ~w(.pdf)

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      # Subscribe to job progress updates
      Phoenix.PubSub.subscribe(LumainusWeb.PubSub, "docling:status")
    end

    socket =
      socket
      |> assign(:uploads, [])
      |> assign(:processing_jobs, %{})
      |> assign(:completed_jobs, [])
      |> assign(:backend_status, :unknown)
      |> allow_upload(:pdf,
          accept: @accepted_types,
          max_entries: 10,
          max_file_size: @max_file_size_mb * 1_000_000,
          auto_upload: true,
          progress: &handle_progress/3)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="upload-page">
      <header class="upload-header">
        <h1>Upload Documents</h1>
        <.backend_status_indicator status={@backend_status} />
      </header>

      <section class="upload-zone" phx-drop-target={@uploads.pdf.ref}>
        <form phx-change="validate" phx-submit="submit">
          <.live_file_input upload={@uploads.pdf} class="hidden" />

          <div class="dropzone">
            <.icon name="hero-document-arrow-up" class="dropzone-icon" />
            <p class="dropzone-text">
              <span class="dropzone-cta">Click to upload</span> or drag and drop
            </p>
            <p class="dropzone-hint">PDF files up to <%= @max_file_size_mb %>MB</p>
          </div>
        </form>

        <!-- Pending uploads -->
        <%= for entry <- @uploads.pdf.entries do %>
          <.upload_entry entry={entry} />
        <% end %>
      </section>

      <!-- Processing jobs (real-time) -->
      <%= if map_size(@processing_jobs) > 0 do %>
        <section class="processing-section">
          <h2>Processing</h2>
          <%= for {job_id, job} <- @processing_jobs do %>
            <.processing_job job={job} />
          <% end %>
        </section>
      <% end %>

      <!-- Completed jobs -->
      <%= if length(@completed_jobs) > 0 do %>
        <section class="completed-section">
          <h2>Completed</h2>
          <%= for job <- @completed_jobs do %>
            <.completed_job job={job} />
          <% end %>
        </section>
      <% end %>
    </div>
    """
  end

  # === COMPONENTS ===

  defp backend_status_indicator(assigns) do
    ~H"""
    <div class={"status-indicator status-#{@status}"}>
      <span class="status-dot"></span>
      <span class="status-text"><%= status_text(@status) %></span>
    </div>
    """
  end

  defp status_text(:healthy), do: "Ready"
  defp status_text(:unhealthy), do: "Starting..."
  defp status_text(:provisioning), do: "Preparing cloud GPU..."
  defp status_text(_), do: "Checking..."

  defp upload_entry(assigns) do
    ~H"""
    <div class="upload-entry">
      <div class="entry-info">
        <.icon name="hero-document" />
        <span class="entry-name"><%= @entry.client_name %></span>
        <span class="entry-size"><%= format_size(@entry.client_size) %></span>
      </div>

      <%= if @entry.progress < 100 do %>
        <div class="entry-progress">
          <div class="progress-bar" style={"width: #{@entry.progress}%"}></div>
        </div>
        <span class="progress-text">Uploading <%= @entry.progress %>%</span>
      <% end %>

      <%= for err <- upload_errors(@uploads.pdf, @entry) do %>
        <p class="entry-error"><%= error_to_string(err) %></p>
      <% end %>
    </div>
    """
  end

  defp processing_job(assigns) do
    ~H"""
    <div class="processing-job">
      <div class="job-header">
        <.icon name="hero-document" />
        <span class="job-name"><%= @job.filename %></span>
      </div>

      <div class="job-progress">
        <div class="progress-bar" style={"width: #{@job.progress}%"}></div>
      </div>

      <div class="job-status">
        <span class="status-message"><%= @job.message %></span>
        <span class="status-percent"><%= @job.progress %>%</span>
      </div>
    </div>
    """
  end

  defp completed_job(assigns) do
    ~H"""
    <div class="completed-job">
      <div class="job-header">
        <.icon name="hero-check-circle" class="success-icon" />
        <span class="job-name"><%= @job.filename %></span>
      </div>

      <div class="job-actions">
        <.link navigate={~p"/documents/#{@job.document_id}"} class="btn-view">
          View Document
        </.link>
        <button phx-click="download" phx-value-id={@job.document_id} class="btn-download">
          Download
        </button>
      </div>
    </div>
    """
  end

  # === EVENT HANDLERS ===

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    # Auto-upload handles this
    {:noreply, socket}
  end

  # Called when upload completes (via auto_upload)
  defp handle_progress(:pdf, entry, socket) when entry.done? do
    consume_uploaded_entry(socket, entry, fn %{path: path} ->
      # 1. Read the file
      {:ok, binary} = File.read(path)

      # 2. Create document and queue processing
      case process_upload(socket, entry, binary) do
        {:ok, job_id, socket} ->
          # Subscribe to this job's progress
          Phoenix.PubSub.subscribe(LumainusWeb.PubSub, "job:#{job_id}")
          {:ok, socket}

        {:error, reason, socket} ->
          {:ok, put_flash(socket, :error, "Upload failed: #{reason}")}
      end
    end)
  end

  defp handle_progress(:pdf, _entry, socket), do: socket

  defp process_upload(socket, entry, binary) do
    user = socket.assigns.current_user

    with {:ok, document} <- Documents.create_document(user, entry.client_name, binary),
         {:ok, job} <- Documents.queue_processing(document) do

      # Add to processing jobs map
      processing_job = %{
        job_id: job.id,
        document_id: document.id,
        filename: entry.client_name,
        progress: 0,
        message: "Queued for processing..."
      }

      socket = update(socket, :processing_jobs, &Map.put(&1, job.id, processing_job))
      {:ok, job.id, socket}
    else
      {:error, reason} ->
        {:error, inspect(reason), socket}
    end
  end

  # === PUBSUB HANDLERS ===

  @impl true
  def handle_info({:docling_status, _mode, status}, socket) do
    {:noreply, assign(socket, :backend_status, status)}
  end

  @impl true
  def handle_info({:job_progress, job_id, payload}, socket) do
    socket = update_job_progress(socket, job_id, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:job_complete, job_id, result}, socket) do
    socket = complete_job(socket, job_id, result)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:job_failed, job_id, error}, socket) do
    socket = fail_job(socket, job_id, error)
    {:noreply, socket}
  end

  # === HELPERS ===

  defp update_job_progress(socket, job_id, payload) do
    update(socket, :processing_jobs, fn jobs ->
      case Map.get(jobs, job_id) do
        nil -> jobs
        job ->
          Map.put(jobs, job_id, %{job |
            progress: payload.progress,
            message: payload.message
          })
      end
    end)
  end

  defp complete_job(socket, job_id, result) do
    {job, remaining} = Map.pop(socket.assigns.processing_jobs, job_id)

    if job do
      completed = %{job | progress: 100, message: "Complete", result: result}
      socket
      |> assign(:processing_jobs, remaining)
      |> update(:completed_jobs, &[completed | &1])
    else
      socket
    end
  end

  defp fail_job(socket, job_id, error) do
    socket
    |> update(:processing_jobs, &Map.delete(&1, job_id))
    |> put_flash(:error, "Processing failed: #{error}")
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp error_to_string(:too_large), do: "File too large (max #{@max_file_size_mb}MB)"
  defp error_to_string(:not_accepted), do: "Only PDF files accepted"
  defp error_to_string(err), do: "Error: #{inspect(err)}"
end
```

---

## Backend Integration: Job Progress Broadcasting

### File: `lib/lumainus/documents/processor.ex` (Simplified)

```elixir
defmodule Lumainus.Documents.Processor do
  @moduledoc """
  Processes documents via Docling.
  Broadcasts progress to LiveView via PubSub.
  """
  require Logger

  alias Lumainus.Backends.Router
  alias Lumainus.Documents

  @stages [
    {0, "Queued for processing..."},
    {10, "Preparing document..."},
    {20, "Connecting to processing backend..."},
    {30, "Converting PDF to markdown..."},
    {50, "Extracting text and structure..."},
    {70, "Processing tables and figures..."},
    {85, "Finalizing conversion..."},
    {95, "Saving results..."},
    {100, "Complete"}
  ]

  def process(job_id) do
    job = Documents.get_job!(job_id)
    document = Documents.get_document!(job.document_id)

    try do
      # Stage: Preparing
      broadcast_progress(job_id, 10, "Preparing document...")

      # Stage: Get backend
      broadcast_progress(job_id, 20, "Connecting to processing backend...")
      {:ok, endpoint} = Router.get_endpoint()

      # Stage: Submit to Docling
      broadcast_progress(job_id, 30, "Converting PDF to markdown...")
      {:ok, conversion_id} = submit_to_docling(endpoint, document)

      # Stage: Poll for completion with progress updates
      result = poll_with_progress(job_id, endpoint, conversion_id)

      # Stage: Save results
      broadcast_progress(job_id, 95, "Saving results...")
      {:ok, _} = Documents.save_conversion_result(document, result)

      # Complete
      broadcast_complete(job_id, %{document_id: document.id})
      :ok

    rescue
      e ->
        Logger.error("Processing failed: #{inspect(e)}")
        broadcast_failed(job_id, Exception.message(e))
        {:error, e}
    end
  end

  defp submit_to_docling(endpoint, document) do
    url = "#{endpoint}/convert"

    case Req.post(url,
      form_multipart: [file: {document.binary, filename: document.filename}],
      receive_timeout: 30_000
    ) do
      {:ok, %{status: 200, body: %{"job_id" => id}}} ->
        {:ok, id}
      {:ok, %{status: status, body: body}} ->
        {:error, "Docling returned #{status}: #{inspect(body)}"}
      {:error, reason} ->
        {:error, "Failed to connect: #{inspect(reason)}"}
    end
  end

  defp poll_with_progress(job_id, endpoint, conversion_id) do
    poll_loop(job_id, endpoint, conversion_id, 0)
  end

  defp poll_loop(job_id, endpoint, conversion_id, attempts) when attempts < 300 do
    url = "#{endpoint}/status/#{conversion_id}"

    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} ->
        case body do
          %{"status" => "complete", "result" => result} ->
            result

          %{"status" => "processing", "progress" => progress} ->
            # Map Docling progress (0-100) to our range (30-85)
            mapped_progress = 30 + round(progress * 0.55)
            message = body["message"] || "Processing page #{body["current_page"] || "?"}..."
            broadcast_progress(job_id, mapped_progress, message)

            Process.sleep(1_000)
            poll_loop(job_id, endpoint, conversion_id, attempts + 1)

          %{"status" => "failed", "error" => error} ->
            raise "Docling conversion failed: #{error}"

          _ ->
            Process.sleep(1_000)
            poll_loop(job_id, endpoint, conversion_id, attempts + 1)
        end

      {:error, reason} ->
        if attempts < 3 do
          Process.sleep(2_000)
          poll_loop(job_id, endpoint, conversion_id, attempts + 1)
        else
          raise "Lost connection to processing backend: #{inspect(reason)}"
        end
    end
  end

  defp poll_loop(_job_id, _endpoint, _conversion_id, _attempts) do
    raise "Processing timeout (5 minutes)"
  end

  # === BROADCAST HELPERS ===

  defp broadcast_progress(job_id, progress, message) do
    Phoenix.PubSub.broadcast(
      LumainusWeb.PubSub,
      "job:#{job_id}",
      {:job_progress, job_id, %{progress: progress, message: message}}
    )
  end

  defp broadcast_complete(job_id, result) do
    Phoenix.PubSub.broadcast(
      LumainusWeb.PubSub,
      "job:#{job_id}",
      {:job_complete, job_id, result}
    )
  end

  defp broadcast_failed(job_id, error) do
    Phoenix.PubSub.broadcast(
      LumainusWeb.PubSub,
      "job:#{job_id}",
      {:job_failed, job_id, error}
    )
  end
end
```

---

## CSS Styles

### File: `assets/css/upload.css`

```css
/* Upload Page */
.upload-page {
  max-width: 800px;
  margin: 0 auto;
  padding: 2rem;
}

.upload-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 2rem;
}

.upload-header h1 {
  font-size: 1.5rem;
  font-weight: 600;
}

/* Status Indicator */
.status-indicator {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.5rem 1rem;
  border-radius: 9999px;
  font-size: 0.875rem;
}

.status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
}

.status-healthy .status-dot { background: #22c55e; }
.status-unhealthy .status-dot { background: #f59e0b; }
.status-provisioning .status-dot { background: #3b82f6; animation: pulse 1s infinite; }
.status-unknown .status-dot { background: #9ca3af; }

@keyframes pulse {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.5; }
}

/* Dropzone */
.dropzone {
  border: 2px dashed #d1d5db;
  border-radius: 0.75rem;
  padding: 3rem;
  text-align: center;
  cursor: pointer;
  transition: all 0.2s;
}

.dropzone:hover,
.dropzone.drag-over {
  border-color: #3b82f6;
  background: #eff6ff;
}

.dropzone-icon {
  width: 48px;
  height: 48px;
  color: #9ca3af;
  margin-bottom: 1rem;
}

.dropzone-cta {
  color: #3b82f6;
  font-weight: 500;
}

.dropzone-hint {
  font-size: 0.875rem;
  color: #6b7280;
  margin-top: 0.5rem;
}

/* Upload Entry */
.upload-entry {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding: 1rem;
  background: #f9fafb;
  border-radius: 0.5rem;
  margin-top: 1rem;
}

.entry-info {
  display: flex;
  align-items: center;
  gap: 0.75rem;
}

.entry-name {
  font-weight: 500;
  flex: 1;
}

.entry-size {
  color: #6b7280;
  font-size: 0.875rem;
}

.entry-progress {
  height: 4px;
  background: #e5e7eb;
  border-radius: 2px;
  overflow: hidden;
}

.progress-bar {
  height: 100%;
  background: #3b82f6;
  transition: width 0.3s ease;
}

.progress-text {
  font-size: 0.75rem;
  color: #6b7280;
}

.entry-error {
  color: #dc2626;
  font-size: 0.875rem;
}

/* Processing Section */
.processing-section,
.completed-section {
  margin-top: 2rem;
}

.processing-section h2,
.completed-section h2 {
  font-size: 1rem;
  font-weight: 600;
  margin-bottom: 1rem;
  color: #374151;
}

/* Processing Job */
.processing-job {
  background: white;
  border: 1px solid #e5e7eb;
  border-radius: 0.5rem;
  padding: 1rem;
  margin-bottom: 0.75rem;
}

.job-header {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin-bottom: 0.75rem;
}

.job-name {
  font-weight: 500;
}

.job-progress {
  height: 8px;
  background: #e5e7eb;
  border-radius: 4px;
  overflow: hidden;
  margin-bottom: 0.5rem;
}

.job-progress .progress-bar {
  background: linear-gradient(90deg, #3b82f6, #8b5cf6);
}

.job-status {
  display: flex;
  justify-content: space-between;
  font-size: 0.875rem;
}

.status-message {
  color: #6b7280;
}

.status-percent {
  font-weight: 500;
  color: #3b82f6;
}

/* Completed Job */
.completed-job {
  background: #f0fdf4;
  border: 1px solid #bbf7d0;
  border-radius: 0.5rem;
  padding: 1rem;
  margin-bottom: 0.75rem;
}

.completed-job .job-header {
  margin-bottom: 0.5rem;
}

.success-icon {
  color: #22c55e;
}

.job-actions {
  display: flex;
  gap: 0.75rem;
}

.btn-view,
.btn-download {
  padding: 0.5rem 1rem;
  border-radius: 0.375rem;
  font-size: 0.875rem;
  font-weight: 500;
  cursor: pointer;
  transition: all 0.2s;
}

.btn-view {
  background: #3b82f6;
  color: white;
}

.btn-view:hover {
  background: #2563eb;
}

.btn-download {
  background: white;
  border: 1px solid #d1d5db;
  color: #374151;
}

.btn-download:hover {
  background: #f9fafb;
}
```

---

## User Experience Flow

### Happy Path

```
1. User navigates to /upload
   → Page loads with green "Ready" indicator

2. User drags PDF onto dropzone
   → File appears with upload progress bar
   → Progress: 0% → 100% (upload)

3. Upload completes
   → File moves to "Processing" section
   → Shows "Queued for processing..."

4. Processing starts
   → Progress: "Connecting to processing backend..."
   → Progress: "Converting PDF to markdown..."
   → Progress: "Processing page 3 of 15..."
   → Progress updates every 1-2 seconds

5. Processing completes
   → File moves to "Completed" section
   → Shows "View Document" and "Download" buttons

6. User clicks "View Document"
   → Navigates to document detail page
```

### Error Paths

```
A. File too large
   → Red error text: "File too large (max 100MB)"
   → Entry shows error, can be dismissed

B. Backend unavailable
   → Status shows "Starting..." (yellow)
   → Upload proceeds, queued until backend ready
   → Auto-retry when backend comes online

C. Processing fails
   → Job disappears from Processing
   → Flash message: "Processing failed: [error]"
   → User can re-upload

D. Network error during upload
   → Upload entry shows error
   → Can retry by re-dropping file
```

---

## Key Differences from Current System

| Aspect | Current (/reports) | New (/upload) |
|--------|-------------------|---------------|
| Backend selection | User chooses profile | Automatic |
| Progress updates | Never (dead channel) | Real-time |
| Error display | Hidden | Immediate |
| Page reload needed | Yes (to see status) | No |
| Files per upload | 1 | Up to 10 |
| Upload feedback | Minimal | Full progress |
| Processing feedback | None | Per-stage |
| Mobile friendly | No | Yes |

---

## Integration Points

### Router
```elixir
# lib/lumainus_web/router.ex
scope "/", LumainusWeb do
  pipe_through [:browser, :require_authenticated_user]

  live "/upload", UploadLive, :index
  # Keep old /reports for backward compat, redirect after migration
end
```

### Navigation
```heex
<nav>
  <.link navigate={~p"/upload"}>Upload Documents</.link>
  <!-- Other links -->
</nav>
```

### Oban Worker
```elixir
# lib/lumainus/workers/document_worker.ex
defmodule Lumainus.Workers.DocumentWorker do
  use Oban.Worker, queue: :documents, max_attempts: 3

  @impl true
  def perform(%{args: %{"job_id" => job_id}}) do
    Lumainus.Documents.Processor.process(job_id)
  end
end
```

---

## Testing Checklist

- [ ] Upload single PDF → progress → complete
- [ ] Upload multiple PDFs → parallel processing
- [ ] Upload while backend starting → queued, then processed
- [ ] Upload too-large file → error shown
- [ ] Upload non-PDF → error shown
- [ ] Processing fails → error flash shown
- [ ] Network disconnect during upload → recoverable
- [ ] Page refresh during processing → state preserved
- [ ] Mobile upload → responsive design works

See `04-IMPLEMENTATION-ROADMAP.md` for the build plan.
