"""FastAPI service exposing Docling PDF -> Markdown conversion."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional
from uuid import uuid4

from fastapi import FastAPI, File, Form, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse

from docling.document_converter import DocumentConverter
from docling.utils.export import generate_multimodal_pages

logger = logging.getLogger("docling_service")
logging.basicConfig(
    level=os.getenv("DOCLING_SERVICE_LOG_LEVEL", "INFO"),
    format="[%(asctime)s] %(levelname)s in %(name)s: %(message)s",
)

app = FastAPI(
    title="Docling Ingestion Service",
    version="0.2.0",
    description=(
        "Private REST endpoint that converts PDFs to Markdown and basic layout"
        " metadata using Docling. Backed by a small in-process worker pool."
    ),
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

_conversion_timeout = float(os.getenv("CONVERSION_TIMEOUT_SECONDS", "1200"))
_worker_count = int(os.getenv("DOC_CONVERTER_WORKERS", "8"))

JOB_QUEUE: asyncio.Queue["ConversionJob"] = asyncio.Queue()
JOB_STORE: Dict[str, "ConversionJob"] = {}


def _now() -> float:
    return time.perf_counter()


def _subscribe(job: ConversionJob) -> asyncio.Queue:
    queue: asyncio.Queue = asyncio.Queue()
    job.subscribers.append(queue)
    return queue


def _unsubscribe(job: ConversionJob, queue: asyncio.Queue) -> None:
    if queue in job.subscribers:
        job.subscribers.remove(queue)


def _push_event(job: ConversionJob, event: Dict[str, Any]) -> None:
    payload = {
        "job_id": job.id,
        "state": job.state,
        "progress": job.progress,
        "pages_done": job.pages_done,
        "pages_failed": getattr(job, "pages_failed", 0),
        "pages_total": job.pages_total,
        "worker_id": job.worker_id,
        "device": job.device,
        "queue_depth": JOB_QUEUE.qsize(),
        "timestamp": time.time(),
        **event,
    }
    job.events.append(payload)
    for subscriber in list(job.subscribers):
        try:
            subscriber.put_nowait(payload)
        except asyncio.QueueFull:
            continue


def _progress_from_pages(pages_done: int, pages_total: Optional[int]) -> float:
    if pages_total and pages_total > 0:
        return round((pages_done / pages_total) * 100.0, 2)
    return 0.0


def _format_sse(event: Dict[str, Any]) -> str:
    event_type = event.get("type", "message")
    return f"event: {event_type}\ndata: {json.dumps(event)}\n\n"


def _detect_device() -> str:
    """Detect the best available device (GPU/MPS/CPU)."""
    try:
        from docling.utils.accelerator_utils import decide_device

        return decide_device("auto")
    except Exception:
        try:
            import torch

            if torch.backends.cuda.is_built() and torch.cuda.is_available():
                try:
                    return f"cuda:{torch.cuda.current_device()}"
                except Exception:
                    return "cuda"
            if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
                return "mps"
        except Exception:
            pass

    return "cpu"


@dataclass
class ConversionJob:
    """In-memory representation of a Docling conversion request."""

    id: str
    source: str
    source_kind: str
    upload_size: Optional[int]
    output_markdown: bool
    cleanup_path: Optional[str] = None
    state: str = "queued"
    progress: float = 0.0
    pages_done: int = 0
    pages_failed: int = 0
    pages_total: Optional[int] = None
    last_error: Optional[str] = None
    error_status: Optional[int] = None
    submitted_at: float = field(default_factory=time.perf_counter)
    started_at: Optional[float] = None
    finished_at: Optional[float] = None
    timeout_at: Optional[float] = None
    result: Optional[Dict[str, Any]] = None
    future: Optional[asyncio.Future] = None
    worker_id: Optional[int] = None
    device: str = "cpu"
    events: List[Dict[str, Any]] = field(default_factory=list)
    subscribers: List[asyncio.Queue] = field(default_factory=list)


def _job_status(job: ConversionJob) -> Dict[str, Any]:
    return {
        "job_id": job.id,
        "state": job.state,
        "progress": job.progress,
        "pages_done": job.pages_done,
        "pages_failed": getattr(job, "pages_failed", 0),
        "pages_total": job.pages_total,
        "last_error": job.last_error,
        "last_message": getattr(job, "last_message", None),
        "queue_depth": JOB_QUEUE.qsize(),
        "submitted_at": job.submitted_at,
        "started_at": job.started_at,
        "finished_at": job.finished_at,
        "timeout_at": job.timeout_at,
        "source_kind": job.source_kind,
        "upload_size": job.upload_size,
        "worker_id": job.worker_id,
        "device": job.device,
        "result": job.result if job.state == "completed" else None,
    }


@app.on_event("startup")
async def _start_workers() -> None:
    for idx in range(_worker_count):
        asyncio.create_task(_worker_loop(idx + 1))
    logger.info("Started %s Docling worker(s)", _worker_count)


async def _worker_loop(worker_id: int) -> None:
    """Background worker that consumes the queue with its own DocumentConverter."""
    converter = DocumentConverter()
    logger.info("Worker %s ready", worker_id)

    while True:
        job: ConversionJob = await JOB_QUEUE.get()
        job.state = "running"
        job.progress = 0.0
        job.started_at = time.perf_counter()
        job.timeout_at = job.timeout_at or (job.started_at + _conversion_timeout)
        job.worker_id = worker_id
        job.device = _detect_device()

        _push_event(
            job,
            {
                "type": "started",
                "message": "Worker picked job",
                "worker_id": worker_id,
                "device": job.device,
            },
        )

        try:
            logger.info(
                "Worker %s starting job %s (kind=%s, size=%s bytes)",
                worker_id,
                job.id,
                job.source_kind,
                job.upload_size,
            )
            result = await asyncio.wait_for(
                _convert_source(
                    converter,
                    job,
                    job.source,
                    job.source_kind,
                    progress_cb=_page_progress_cb(job),
                    docling_progress_cb=_docling_progress_cb(job),
                ),
                timeout=_conversion_timeout,
            )
            if not job.output_markdown and isinstance(result, dict):
                result.pop("markdown", None)
            job.result = result
            job.state = "completed"
            job.progress = 100.0
            job.finished_at = _now()
            _push_event(
                job,
                {
                    "type": "completed",
                    "message": "Docling conversion completed",
                    "elapsed_ms": int((job.finished_at - job.started_at) * 1000)
                    if job.started_at
                    else None,
                },
            )
        except asyncio.TimeoutError:
            job.last_error = "Docling conversion timed out"
            job.error_status = 504
            job.state = "failed"
            job.progress = 100.0
            job.finished_at = _now()
            logger.error("Worker %s timed out job %s", worker_id, job.id)
            _push_event(
                job,
                {
                    "type": "timeout",
                    "message": job.last_error,
                },
            )
        except Exception as err:  # pragma: no cover - surfaced to client
            job.last_error = str(err)
            job.error_status = 500
            job.state = "failed"
            job.progress = 100.0
            job.finished_at = _now()
            logger.exception("Worker %s failed job %s", worker_id, job.id)
            _push_event(
                job,
                {
                    "type": "failed",
                    "message": job.last_error,
                },
            )
        finally:
            if job.future and not job.future.done():
                job.future.set_result(job.result)
            if job.cleanup_path and os.path.exists(job.cleanup_path):
                os.unlink(job.cleanup_path)
            JOB_QUEUE.task_done()


def _page_progress_cb(job: ConversionJob):
    started = job.started_at or _now()

    def _cb(page_number: int, pages_total: Optional[int]) -> None:
        current_pages_done = job.pages_done or 0

        # Do not regress progress if Docling already reported further pages
        if page_number <= current_pages_done:
            return

        job.pages_done = page_number
        job.pages_total = pages_total or job.pages_total
        new_progress = _progress_from_pages(page_number, job.pages_total)
        job.progress = max(job.progress or 0.0, new_progress)
        _push_event(
            job,
            {
                "type": "page_processed",
                "page_number": page_number,
                "pages_total": pages_total,
                "elapsed_ms": int((_now() - started) * 1000),
                "message": f"Processed page {page_number}"
                + (f"/{pages_total}" if pages_total else ""),
            },
        )

    return _cb


def _docling_progress_cb(job: ConversionJob):
    """Create a progress callback for Docling's internal progress events."""
    started = job.started_at or _now()

    def _cb(event: Dict[str, Any]) -> None:
        event_type = event.get("event", "unknown")

        # Update job state based on event
        if "pages_done" in event:
            job.pages_done = event["pages_done"]
        if "pages_total" in event:
            job.pages_total = event["pages_total"]
        if "pages_failed" in event:
            job.pages_failed = event.get("pages_failed")

        # Always calculate progress from pages (ignore docling's progress field - unreliable)
        if job.pages_total and job.pages_total > 0:
            calculated = round((job.pages_done / job.pages_total) * 100.0, 2)
            job.progress = min(max(calculated, 0.0), 100.0)

        # Map Docling events to our event format
        mapped_type = {
            "conversion_started": "docling_started",
            "page_processed": "page_processed",
            "page_failed": "page_failed",
            "stage_batch_complete": "stage_complete",
            "conversion_completed": "docling_completed",
            "conversion_timeout": "docling_timeout",
            "conversion_failed": "docling_failed",
        }.get(event_type, event_type)

        _push_event(
            job,
            {
                "type": mapped_type,
                "elapsed_ms": int((_now() - started) * 1000),
                "stage_seq": event.get("stage_seq"),
                **{k: v for k, v in event.items() if k != "event"},
            },
        )

        # Log significant events
        if event_type in ("page_processed", "stage_batch_complete"):
            logger.info(
                "Job %s: %s - %s",
                job.id,
                event_type,
                event.get("message", ""),
            )

    return _cb


async def _convert_source(
    converter: DocumentConverter,
    job: Job,
    source: str,
    source_kind: str,
    progress_cb: Optional[Callable[[int, Optional[int]], None]] = None,
    docling_progress_cb: Optional[Callable[[Dict[str, Any]], None]] = None,
) -> Dict[str, Any]:
    """Run Docling conversion in a worker thread."""

    def _sync_convert() -> Dict[str, Any]:
        progress_context = {
            "job_id": job.id,
            "worker_id": job.worker_id,
            "device": job.device,
            "source_kind": job.source_kind,
            "upload_size": job.upload_size,
        }
        conversion = converter.convert(
            source,
            progress_callback=docling_progress_cb,
            progress_context=progress_context,
        )
        document = conversion.document
        if document is None:
            raise RuntimeError("Docling returned an empty document")

        markdown = document.export_to_markdown()
        pages = _build_pages(conversion, progress_cb)
        metadata = {
            "page_count": len(conversion.pages or []),
            "source_kind": source_kind,
            "has_tables": any(
                any(seg.get("label") == "table" for seg in page["segments"])
                for page in pages
            ),
        }

        return {
            "success": True,
            "markdown": markdown,
            "metadata": metadata,
            "pages": pages,
        }

    return await asyncio.to_thread(_sync_convert)


def _build_pages(
    conversion, progress_cb: Optional[Callable[[int, Optional[int]], None]] = None
) -> List[Dict[str, Any]]:
    pages_total = len(getattr(conversion, "pages", []) or []) or None
    pages = []
    for idx, (
        text,
        markdown,
        _tokens,
        cells,
        segments,
        page,
    ) in enumerate(generate_multimodal_pages(conversion), start=1):
        pages.append(
            {
                "page_number": getattr(page, "page_no", idx),
                "text": (text or "").strip(),
                "markdown": (markdown or "").strip(),
                "cells": cells,
                "segments": segments,
            }
        )
        if progress_cb:
            try:
                progress_cb(idx, pages_total)
            except Exception:
                logger.exception("Progress callback failed for page %s", idx)

    if not pages:
        pages.append(
            {
                "page_number": 1,
                "text": conversion.document.export_to_markdown(),
                "markdown": conversion.document.export_to_markdown(),
                "cells": [],
                "segments": [],
            }
        )

    return pages


async def _persist_upload(upload: UploadFile) -> tuple[str, int]:
    """Persist an uploaded file to a temporary path and return it."""
    suffix = Path(upload.filename or "document.pdf").suffix or ".pdf"
    fd, tmp_path = tempfile.mkstemp(suffix=suffix)
    total_bytes = 0

    try:
        with os.fdopen(fd, "wb") as tmp:
            while True:
                chunk = await upload.read(1_048_576)
                if not chunk:
                    break
                total_bytes += len(chunk)
                tmp.write(chunk)
        logger.info("Saved uploaded file to %s (%s bytes)", tmp_path, total_bytes)
        return tmp_path, total_bytes
    except Exception:
        os.unlink(tmp_path)
        raise


async def _await_job_result(job: ConversionJob, wait_timeout: Optional[float] = None) -> Dict[str, Any]:
    try:
        await asyncio.wait_for(
            asyncio.shield(job.future),
            timeout=wait_timeout or (_conversion_timeout + 5),
        )
    except asyncio.TimeoutError as err:
        raise HTTPException(status_code=504, detail="Docling conversion timed out") from err

    if job.state == "completed" and job.result is not None:
        return job.result

    raise HTTPException(
        status_code=job.error_status or 500,
        detail=job.last_error or "Docling conversion failed",
    )


async def _enqueue_job(
    source_to_convert: str,
    source_kind: str,
    upload_size: Optional[int],
    output_markdown: bool,
    *,
    cleanup_path: Optional[str] = None,
    wait: bool = False,
    client_job_id: Optional[str] = None,
) -> Dict[str, Any]:
    # Use client-provided job_id if given, otherwise generate one
    job_id = client_job_id if client_job_id else str(uuid4())
    loop = asyncio.get_running_loop()

    job = ConversionJob(
        id=job_id,
        source=source_to_convert,
        source_kind=source_kind,
        upload_size=upload_size,
        output_markdown=output_markdown,
        cleanup_path=cleanup_path,
        timeout_at=time.perf_counter() + _conversion_timeout,
    )
    job.future = loop.create_future()
    JOB_STORE[job.id] = job

    await JOB_QUEUE.put(job)
    _push_event(
        job,
        {"type": "queued", "message": "Queued for Docling conversion"},
    )

    logger.info(
        "Queued Docling job %s (kind=%s, size=%s bytes, queue_depth=%s, wait=%s)",
        job.id,
        source_kind,
        upload_size,
        JOB_QUEUE.qsize(),
        wait,
    )

    if wait:
        return await _await_job_result(job)

    return _job_status(job)


async def _schedule_conversion(
    source_url: Optional[str],
    file: Optional[UploadFile],
    output_markdown: bool,
    *,
    wait: bool,
    client_job_id: Optional[str] = None,
) -> Dict[str, Any]:
    if not source_url and file is None:
        raise HTTPException(
            status_code=400,
            detail="Provide either a source_url query parameter or upload a PDF file.",
        )

    temp_path: Optional[str] = None
    source_kind = "url"
    source_to_convert = source_url

    upload_size: Optional[int] = None

    if not source_url:
        source_kind = "upload"
        temp_path, upload_size = await _persist_upload(file)  # type: ignore[arg-type]
        source_to_convert = temp_path
    elif source_to_convert:
        try:
            upload_size = Path(source_to_convert).stat().st_size
        except OSError:
            upload_size = None

    return await _enqueue_job(
        source_to_convert,  # type: ignore[arg-type]
        source_kind,
        upload_size,
        output_markdown,
        cleanup_path=temp_path,
        wait=wait,
        client_job_id=client_job_id,
    )


@app.get("/health", summary="Service health check")
async def health() -> Dict[str, str]:
    return {"status": "ok"}


@app.post(
    "/convert",
    summary="Convert a PDF to Markdown",
    response_description="Markdown + layout metadata",
)
async def convert_document(
    source_url: Optional[str] = Query(
        default=None,
        description="Public URL to a PDF. Provide this or upload a file.",
    ),
    output_markdown: bool = Query(
        default=True,
        description="Whether to include the merged Markdown output in the response.",
    ),
    file: Optional[UploadFile] = File(
        default=None,
        description="PDF upload. Ignored if source_url is provided.",
    ),
) -> JSONResponse:
    result = await _schedule_conversion(
        source_url, file, output_markdown, wait=True
    )
    return JSONResponse(content=result)


@app.post(
    "/jobs",
    summary="Queue a Docling conversion job",
    response_description="Job identifier and status",
)
async def queue_job(
    source_url: Optional[str] = Query(
        default=None,
        description="Public URL to a PDF. Provide this or upload a file.",
    ),
    output_markdown: str = Form(
        default="true",
        description="Whether to include the merged Markdown output in the result.",
    ),
    wait: str = Form(
        default="false",
        description="If true, block until the Docling job finishes and return the result.",
    ),
    job_id: Optional[str] = Form(
        default=None,
        description="Client-provided job ID. If not provided, server generates one.",
    ),
    file: Optional[UploadFile] = File(
        default=None,
        description="PDF upload. Ignored if source_url is provided.",
    ),
) -> JSONResponse:
    # Parse string booleans from form data
    output_markdown_bool = output_markdown.lower() == "true"
    wait_bool = wait.lower() == "true"

    job_response = await _schedule_conversion(
        source_url, file, output_markdown_bool, wait=wait_bool, client_job_id=job_id
    )
    return JSONResponse(content=job_response)


@app.get("/jobs/{job_id}/status", summary="Get status for a queued job")
async def job_status(job_id: str) -> JSONResponse:
    job = JOB_STORE.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")

    return JSONResponse(content=_job_status(job))


@app.get("/jobs/{job_id}/stream", summary="Stream job events (SSE)")
async def job_stream(job_id: str) -> StreamingResponse:
    job = JOB_STORE.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")

    queue = _subscribe(job)

    async def event_generator():
        try:
            for event in job.events:
                yield _format_sse(event)
            while True:
                event = await queue.get()
                yield _format_sse(event)
        finally:
            _unsubscribe(job, queue)

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache"},
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host=os.getenv("HOST", "0.0.0.0"),
        port=int(os.getenv("PORT", "8042")),
        reload=os.getenv("RELOAD", "false").lower() == "true",
    )
