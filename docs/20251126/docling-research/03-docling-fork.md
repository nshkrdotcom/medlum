# Docling Fork Analysis

**Date:** November 26, 2025
**Location:** `docling/` (within medlum project)
**Status:** Active fork with custom telemetry extensions
**Version:** `2.63.0+medlum`

---

## Executive Summary

The Medlum fork extends Docling 2.63.0 with **real-time progress telemetry** for medical document ingestion pipelines. Core modifications add a callback API that enables page-by-page progress tracking during PDF conversion.

---

## Fork Overview

### Repository Details

- **Location:** `\\wsl.localhost\ubuntu-dev\home\home\p\g\n\medlum\docling`
- **Remote (origin):** `n:nshkrdotcom/docling.git`
- **Remote (upstream):** `https://github.com/docling-project/docling.git`
- **Base Version:** 2.63.0 (stable)

### Key Differences from Upstream

1. **Progress Callback API** (Latest commit: Nov 23, 2025)
   - Added `progress_callback` parameter to `DocumentConverter.convert()` and `convert_all()` methods
   - Callbacks receive structured event dictionaries with lifecycle tracking
   - Events include: type, page counts, progress percentage, stage-specific metadata

2. **Telemetry Events**
   - **Lifecycle events**: `conversion_started`, `page_processed`, `conversion_timeout`, `conversion_completed`
   - **Per-page events**: `page_processed` (with error details), `page_failed`
   - **Stage events**: `stage_batch_complete` (with batch_size, elapsed_ms)
   - All events track: `pages_done`, `pages_total`, `progress` percentage

3. **Pipeline Extensions**
   - Enhanced `BasePipeline` with `_emit_progress()` helper (wraps callbacks with error handling)
   - Extended `StandardPdfPipeline` with per-page event emission
   - Propagates `progress_callback` through all threaded pipeline stages

4. **Configuration Updates**
   - Added `arbitrary_types_allowed=True` to Pydantic ConfigDict to support Callable types
   - Added `progress_callback` field to `PipelineOptions` with `exclude=True`

---

## Modified Files

```
docling/document_converter.py          # +imports, +progress_callback param
docling/datamodel/pipeline_options.py  # +Callable field
docling/pipeline/base_pipeline.py      # +_emit_progress method
docling/pipeline/standard_pdf_pipeline.py  # +per-page event emission
pyproject.toml                         # version string marked "+medlum"
docs/20251120/telemetry.md             # design documentation
```

---

## Progress Callback Design

### Upstream (2.63.0)
No progress feedback mechanism.

### Medlum Fork (2.63.0+medlum)

1. **Add callback during conversion initialization:**
   ```python
   converter.convert(pdf_binary, progress_callback=my_callback)
   ```

2. **Callback receives event dictionaries:**
   ```python
   def my_callback(event: Dict[str, Any]):
       event_type = event.get("type")
       if event_type == "page_processed":
           print(f"Page {event['page_no']}/{event['pages_total']}")
           print(f"Progress: {event['progress']}%")
   ```

3. **Event Lifecycle:**
   - **conversion_started**: Job begins, includes `pages_total` (if known)
   - **page_processed**: Page completed, includes `page_no`, `progress`, `pages_done`
   - **page_failed**: Page error, includes error details
   - **stage_batch_complete**: Pipeline stage batch done
   - **conversion_completed**: Job success
   - **conversion_timeout**: Exceeded document_timeout

### Error Handling
- Callback exceptions wrapped in try-catch
- Warnings logged on callback errors
- **Conversion continues even if callback fails** (non-blocking telemetry)

---

## API Endpoints & Contracts

### Backend HTTP API (Exposed by docling_service)

#### 1. Synchronous Conversion
```http
POST /convert
Content-Type: multipart/form-data

Parameters:
  file (binary): PDF file
  output_markdown (string): "true" for markdown output

Response (200):
{
  "markdown": "## Title\n\nContent...",
  "metadata": {
    "page_count": 5,
    "processing_time": 2.3
  },
  "result": { ... }
}
```

#### 2. Asynchronous Job Submission
```http
POST /jobs
Content-Type: multipart/form-data

Parameters:
  file (binary): PDF file
  output_markdown (string): "true"
  wait (string): "false"
  [job_id (string)]: custom job ID

Response (202):
{
  "job_id": "uuid-or-custom-id",
  "status": "queued",
  "pages_total": null
}
```

#### 3. Job Status (Polling)
```http
GET /jobs/{job_id}/status

Response (200):
{
  "job_id": "...",
  "state": "running" | "completed" | "failed" | "timeout",
  "progress": 45,
  "pages_done": 2,
  "pages_total": 5,
  "pages_failed": 0,
  "elapsed_ms": 1200,
  "queue_depth": 3,
  "worker_id": "worker-1",
  "device": "cuda:0",
  "last_message": "Processing page 3...",
  "last_error": null,
  "type": "page_processed" | "stage_batch_complete",
  "stage": "layout" | "ocr" | "table",
  "stage_seq": 2,
  "result": { "markdown": "...", "metadata": {...} }
}
```

#### 4. Server-Sent Events Stream (Preferred)
```http
GET /jobs/{job_id}/stream

Response (200 text/event-stream):
event: job_started
data: {"job_id": "...", "pages_total": 5, "state": "running"}

event: page_processed
data: {"job_id": "...", "page_no": 1, "pages_done": 1, "progress": 20}

event: page_failed
data: {"job_id": "...", "page_no": 2, "error": "OCR failed"}

event: stage_batch_complete
data: {"stage": "layout", "batch_size": 2, "elapsed_ms": 450}

event: job_completed
data: {"state": "completed", "result": {...}}

event: job_failed
data: {"state": "failed", "last_error": "..."}

event: job_timeout
data: {"state": "timeout"}
```

#### 5. Job Cancellation
```http
DELETE /jobs/{job_id}

Response (200):
{
  "job_id": "...",
  "state": "cancelled",
  "message": "Job cancelled successfully"
}
```

#### 6. Health Check
```http
GET /health

Response (200):
{
  "status": "healthy",
  "uptime": 3600,
  "queue_depth": 2,
  "workers": [
    {"id": "worker-1", "device": "cuda:0", "active": true}
  ]
}
```

---

## Integration with Medlum

### Data Flow

```
Phoenix Web UI (LiveView)
    |
    v
Medlum.Docling API (Elixir facade)
    |
    v
Backend Router (resolve local/cloud)
    |
    v
HTTP Transport (Medlum.Docling.HTTP)
    |
    v
Local Service (/jobs, /jobs/{id}/stream) OR Vast.ai Cloud
    |
    v
Docling Fork (Python + telemetry callbacks)
    |
    v
SSE Events -> Phoenix PubSub -> LiveView Progress Cards
```

### Example Usage (Elixir)

```elixir
# Synchronous conversion
{:ok, result} = Medlum.Docling.convert(pdf_binary,
  filename: "document.pdf",
  backend: :docker_gpu
)
markdown = result["markdown"]

# Asynchronous with progress streaming
{:ok, job} = Medlum.Docling.enqueue(pdf_binary,
  filename: "document.pdf",
  mode: :local
)

{:ok, result} = Medlum.Docling.await(job,
  on_status: fn status ->
    progress = status["progress"] || 0
    IO.inspect("Progress: #{progress}%")
  end,
  prefer_sse: true
)

# Cloud mode with auto-provisioning
{:ok, result} = Medlum.Docling.convert(pdf_binary,
  filename: "document.pdf",
  mode: :cloud
)
```

---

## Docker & Deployment

### Docling Service Setup

**Scripts**: `docling/scripts/`
- `setup_docling_service.sh native_cpu` - Start port 8040 (CPU)
- `setup_docling_service.sh native_gpu` - Start port 8041 (GPU)
- `docling-compose.sh up` - Docker Compose (CPU)

**Dockerfile**: Standard Python 3.11 slim image with docling package + models pre-downloaded

---

## Performance & Limits

| Metric | Value | Notes |
|--------|-------|-------|
| Default timeout | 20 minutes | Configurable via `timeout_ms` |
| Poll interval | 250ms | Configurable |
| Page timeout | Document-level | Respects `document_timeout` |
| Vast.ai cost | ~$0.18/hour | RTX 3090 GPU pricing |

---

## Git History

**Latest Commit**: `17fd168` (Nov 23, 2025)
"Docling progress callback API for real-time conversion telemetry"

**Fork Relationship**:
- **Origin**: `n:nshkrdotcom/docling.git` (GitHub nshkrdotcom fork)
- **Upstream**: `https://github.com/docling-project/docling.git` (Official)
- **Base Version**: 2.63.0 (stable)

---

## Maintenance Considerations

### Keeping in Sync with Upstream

1. **Regular merges** from upstream to get bug fixes and features
2. **Conflict resolution** in modified files (document_converter.py, pipeline files)
3. **Testing** telemetry features after merge

### Model Compatibility

- Fork uses same models as upstream
- No model modifications
- Model versions tracked in pyproject.toml

### API Stability

- Progress callback API is additive (backward compatible)
- SSE event format documented in `docs/20251120/telemetry.md`
- Breaking changes should be versioned

---

## Summary

The Medlum Docling fork is a **production integration** that extends the official Docling 2.63.0 library with:

1. **Real-time progress tracking** via Python callback API
2. **SSE-first streaming** for Elixir/Phoenix integration
3. **Non-blocking telemetry** (errors don't stop conversion)
4. **Documented API contracts** for all endpoints

**Key Innovation**: Bridges Python document processing (Docling) with Elixir real-time web (Phoenix) using standardized HTTP + SSE patterns.
