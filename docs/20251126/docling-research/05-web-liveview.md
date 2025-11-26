# Web/LiveView Integration for Docling

**Date:** November 26, 2025
**Component:** `lib/lumainus_web/`

---

## Executive Summary

The lumainus project implements a sophisticated web-based interface for PDF-to-Markdown conversion using Docling. The architecture separates concerns into admin management, user-facing document processing, and real-time status tracking.

---

## 1. Route Configuration

**File:** `lib/lumainus_web/router.ex`

```elixir
# Public API for document uploads and job monitoring
scope "/api", LumainusWeb do
  pipe_through :api
  post "/uploads", Api.UploadController, :create
  get "/uploads/:id/status", Api.UploadController, :status
  get "/uploads/:id/download", Api.UploadController, :download_markdown
  get "/jobs/:id/status", Api.JobController, :status
  get "/jobs/:id/stream", Api.JobController, :stream
end

# Doctor routes - document processing
scope "/", LumainusWeb do
  live_session :doctor_routes do
    live "/reports", ReportsLive
    live "/prompts", PromptsLive
  end
end

# Admin routes - system configuration
scope "/admin", LumainusWeb do
  live_session :admin_routes do
    live "/docling", Admin.DoclingSettingsLive
    live "/vast_ai", Admin.VastAILive
    live "/gpu_events", Admin.GPUEventsLive
  end
end
```

---

## 2. Admin Settings UI

### DoclingSettingsLive Component

**File:** `lib/lumainus_web/live/admin/docling_settings_live.ex`

**Purpose:** Centralized admin interface for configuring Docling backends and monitoring their health.

**Key Features:**
- Real-time health status monitoring for all 5 backends
- Backend URL configuration (all 5 endpoints)
- Mode selection (local vs cloud)
- Active local backend selection
- Timing/timeout configuration
- Live health check refresh button

**Backend Health Monitoring:**

```
+------------------------------------------------------------+
|                    Backend Health Grid                      |
+------------------------------------------------------------+
| Native CPU  | Native GPU  | Docker CPU | Docker GPU | Cloud |
| Port 8040   | Port 8041   | Port 8042  | Port 8043  | 8044  |
| (CPU)       | (GPU)       | (CPU)      | (GPU)      | (GPU) |
| [Status]    | [Status]    | [Status]   | [Status]   | [St]  |
+------------------------------------------------------------+
```

**Health Check Logic:**
- Local backends: HTTP health endpoint check
- Cloud backend (vast_ai): State machine-based health tracking
- Status states: `healthy`, `unreachable`, `unconfigured`, `checking`, `loading`, `stopped`, `no_instance`

**Mount Behavior:**
```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    InstanceManager.subscribe()  # Real-time GPU status updates
  end

  {:ok,
   socket
   |> assign_settings()        # Load current DB settings
   |> assign_all_health()}     # Check health of all backends
end
```

---

## 3. Document Processing Flow

### User Upload Flow in ReportsLive

**File:** `lib/lumainus_web/live/reports_live.ex`

**LiveView Upload Setup:**
```elixir
allow_upload(:documents,
  accept: ~w(.pdf),
  max_entries: 5,
  max_file_size: 25_000_000,  # 25 MB
  auto_upload: true,
  progress: &handle_upload_progress/3
)
```

**Step-by-Step Processing:**

1. **File Selection & Upload (Client-Side)**
   - User selects up to 5 PDF files
   - LiveView automatically uploads via AJAX
   - Progress callback fires as bytes arrive

2. **Upload Progress Handler**
   ```elixir
   defp handle_upload_progress(:documents, entry, socket) do
     if entry.done? do
       consume_uploaded_entry(socket, entry, fn %{path: path} ->
         case read_uploaded_file(path, entry) do
           {:ok, payload} -> {:ok, {:success, payload}}
           {:error, reason} -> {:ok, {:error, reason}}
         end
       end)
     else
       {:noreply, socket}
     end
   end
   ```

3. **Database & Job Queuing**
   - **Create Upload**: Store binary in DB, compute SHA256 digest for deduplication
   - **Create Job**: Create ingestion job record with status tracking
   - **Queue Job**: Enqueue Oban job for background processing

### Upload Controller API

**File:** `lib/lumainus_web/controllers/api/upload_controller.ex`

**Endpoints:**
- `POST /api/uploads` - Accept multipart form data with file
- `GET /api/uploads/:id/status` - Get upload and job status
- `GET /api/uploads/:id/download` - Download processed markdown

**Deduplication logic:**
```elixir
defp existing_upload(tenant_id, binary) do
  digest = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  DocumentUpload |> Repo.get_by(tenant_id: tenant_id, sha256: digest)
end
```

---

## 4. Admin GPU & Cloud Management

### VastAILive Component

**File:** `lib/lumainus_web/live/admin/vast_ai_live.ex`

**Purpose:** Manage cloud GPU instances on Vast.ai

**Key Responsibilities:**
- Display available Vast.ai offers (GPU instances)
- Filter offers by price, VRAM, availability
- Provision new instances
- Monitor provisioning progress via state machine & PubSub
- Handle HTTPS tunnel provisioning (via Caddy)
- Auto-shutdown configuration

**Real-Time Features:**
- Subscribes to `ProvisioningState` for live provision status updates
- Listens to events:
  - `:provisioning_started`
  - `:log_added` (streaming provision logs)
  - `:status_updated`
  - `:provisioning_complete`
  - `:provisioning_failed`
  - `:logs_cleared`

### GPUEventsLive Component

**File:** `lib/lumainus_web/live/admin/gpu_events_live.ex`

**Purpose:** Event history and analytics for GPU usage

**Features:**
- Event logs (creation, start, stop, errors)
- Session history (duration, cost)
- Statistics (total cost, average duration)
- Filtering by category, severity, instance ID, time range

---

## 5. Database Schema & Configuration

### Settings Schema

**File:** `lib/lumainus/docling/setting.ex`

**Database Table:** `docling_settings` (singleton)

**Fields:**
```elixir
# User-facing mode selection
field(:default_mode, :string)           # "local" | "cloud"
field(:active_local_backend, :string)   # "native_cpu" | etc.

# Backend URLs (all 5)
field(:native_cpu_url, :string)         # http://127.0.0.1:8040
field(:native_gpu_url, :string)         # http://127.0.0.1:8041
field(:docker_cpu_url, :string)         # http://127.0.0.1:8042
field(:docker_gpu_url, :string)         # http://127.0.0.1:8043
field(:cloud_url, :string)              # https://...vastai...

# Timing
field(:timeout_ms, :integer)            # 1_200_000 (20 min)
field(:poll_interval_ms, :integer)      # 250ms
field(:progress_min_interval_ms, :integer) # 50ms
```

---

## 6. Background Job Processing

### DoclingIngestionWorker

**File:** `lib/lumainus/documents/docling_ingestion_worker.ex`

**Oban Configuration:**
```elixir
use Oban.Worker,
  queue: :ingestion,
  max_attempts: 3,
  priority: 1
```

**Processing Pipeline:**

```
User Upload
    |
    v
[ReportsLive] consume_uploaded_entry
    |
    v
[Documents] create_upload + queue_ingestion
    |
    v
[Oban] Insert DoclingIngestionWorker job
    |
    v
[Worker] perform/1 with timeout handling
    |-- Circuit breaker checks
    |-- Task.async(IngestionProcessor.process)
    |-- Task.yield(task, timeout_ms)
    |-- Handle result or error
    |
    v
[Job Result]
|-- :ok -> Job complete
|-- {:error, reason} -> Retry (if attempts remaining)
|-- {:cancel, reason} -> Job failed, don't retry
```

---

## 7. Real-Time Updates & PubSub

### ReportsLive Real-Time Integration

**Subscriptions on Mount:**
```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    Documents.subscribe_to_record_set(socket.assigns.record_set.id)
    InstanceManager.subscribe()
  end
  {:ok, socket}
end
```

**Handle Info Messages:**

1. **`:documents_changed`** - When new uploads appear or status changes
2. **`:job_progress`** - Real-time job status updates
3. **`:gpu_status_changed`** - GPU instance status from InstanceManager

### Job Controller - Server-Sent Events (SSE)

**File:** `lib/lumainus_web/controllers/api/job_controller.ex`

**Streaming Endpoint:**
```elixir
def stream(conn, %{"id" => job_id}) do
  Documents.subscribe_to_ingestion_job(job_id)

  conn
  |> put_resp_header("cache-control", "no-cache")
  |> put_resp_content_type("text/event-stream")
  |> send_chunked(200)
  |> chunk(encode_sse("progress", initial_payload))
  |> stream_loop()
end
```

**SSE Message Format:**
```
event: progress
data: {"id":"job-123","status":"processing","progress":45}

event: ping
data: {}

event: progress
data: {"id":"job-123","status":"completed","stage":"completed"}
```

---

## 8. Data Flow Diagram

```
+------------------------------------------------------------------+
|                         User Flow                                 |
+------------------------------------------------------------------+
|                                                                    |
|  [User] -> ReportsLive File Upload                                |
|              |                                                     |
|              v                                                     |
|         [allow_upload] + auto_upload: true                        |
|              |                                                     |
|              v                                                     |
|         handle_upload_progress(:documents, entry, socket)         |
|              |                                                     |
|              v                                                     |
|         Documents.create_upload(scope, patient, record_set, ...)  |
|              |-- Check SHA256 dedup                               |
|              |-- Store binary in DB                               |
|              v                                                     |
|         Documents.queue_ingestion(upload, template, backend: ...) |
|              |-- Create IngestionJob + Oban job                   |
|              v                                                     |
|     [PubSub] :documents_changed broadcast                         |
|              |                                                     |
|              v                                                     |
|  [Browser] ReportsLive receives :documents_changed                |
|              |                                                     |
|              v                                                     |
|       [UI] Show document with status: queued -> processing -> ok  |
|                                                                    |
+------------------------------------------------------------------+

+------------------------------------------------------------------+
|                       Backend Processing                          |
+------------------------------------------------------------------+
|                                                                    |
|  [Oban] Ingestion Queue (priority: 1, max_attempts: 3)           |
|         DoclingIngestionWorker.perform(job_args)                 |
|              |                                                     |
|              v                                                     |
|         Circuit breaker checks:                                   |
|         - cancelled_at set? -> cancel                             |
|         - deadline_exceeded? -> cancel                            |
|              |                                                     |
|              v (if OK)                                            |
|     Task.async(IngestionProcessor.process(job.id))               |
|              |                                                     |
|              v                                                     |
|     IngestionProcessor.process(job_id)                           |
|         |-- Fetch job + upload binary                            |
|         |-- Resolve backend (from job.backend or active)         |
|         |-- Call Docling.enqueue(binary, backend: ...)           |
|         |-- Call Docling.await(job, backend: ...)                |
|         |-- Parse markdown result                                 |
|         |-- Store in DocumentParse + IngestionEvent              |
|              |                                                     |
|              v                                                     |
|     [PubSub] :job_progress broadcast (on each status check)      |
|              |                                                     |
|              v                                                     |
|  [Browser] ReportsLive receives :job_progress                    |
|              |                                                     |
|              v                                                     |
|          Update document progress in real-time                    |
|                                                                    |
+------------------------------------------------------------------+
```

---

## 9. API Surface Summary

### Public HTTP API

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/uploads` | POST | Submit PDF for conversion |
| `/api/uploads/:id/status` | GET | Get upload/job status |
| `/api/uploads/:id/download` | GET | Download markdown result |
| `/api/jobs/:id/status` | GET | Get job details |
| `/api/jobs/:id/stream` | GET | Stream job progress (SSE) |

### LiveView Events

**ReportsLive:**
- `"set_docling_backend"` - Switch between local/cloud
- `"boot_gpu_and_enable"` - Provision GPU and enable cloud
- `"start_gpu"` / `"stop_gpu"` - GPU control
- `"delete_document"` - Remove upload
- `"retry_ingestion"` - Retry failed processing
- `"run_section"` - Generate report section

**DoclingSettingsLive:**
- `"save"` - Save configuration changes
- `"refresh_health"` - Manually refresh backend health

**VastAILive:**
- `"provision_instance"` - Start provisioning
- `"cancel_provisioning"` - Stop provision process
- `"start_instance"` / `"stop_instance"` / `"delete_instance"`

---

## 10. PubSub Channels

- `documents:record_set:#{record_set_id}` - Document changes
- `ingestion:record_set:#{record_set_id}` - Job progress
- `gpu:status` - GPU instance status updates
- `provisioning` - Vast.ai provisioning events

---

## 11. Error Handling & Resilience

**Upload Validation:**
- File size limit: 25 MB (configurable)
- File types: `.pdf` only
- Duplicate detection: SHA256 hash-based

**Processing Resilience:**
- Timeout protection: 20 minute max per job
- Circuit breaker: Hard deadline prevents retries
- Retry policy: Up to 3 attempts
- Error history: All errors recorded for debugging
- Fallback strategy: SSE fails -> polling

**URL Validation:**
- HTTPS required (except localhost)
- Enforced at schema level via Ecto validators
