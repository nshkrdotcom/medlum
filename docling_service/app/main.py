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
from typing import Any, Dict, List, Optional
from uuid import uuid4

from contextlib import asynccontextmanager

from fastapi import FastAPI, File, Form, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse

from docling.datamodel.base_models import ConversionStatus, InputFormat
from docling.datamodel.document import ConversionResult
from docling.datamodel.pipeline_options import ThreadedPdfPipelineOptions
from docling.datamodel.progress import (
    ConversionPhase,
    ConversionProgressEvent,
    DocumentCompletedProgress,
    DocumentStartedProgress,
    PageCompletedProgress,
    PhaseStartedProgress,
)
from docling.document_converter import DocumentConverter, PdfFormatOption
from docling.utils.accelerator_utils import decide_device
from docling_core.types.doc import DocItem, TableItem

logger = logging.getLogger("docling_service")
logging.basicConfig(
    level=os.getenv("DOCLING_SERVICE_LOG_LEVEL", "INFO"),
    format="[%(asctime)s] %(levelname)s in %(name)s: %(message)s",
)

@asynccontextmanager
async def lifespan(_app: FastAPI):
    workers = [
        asyncio.create_task(_worker_loop(idx + 1)) for idx in range(_worker_count)
    ]
    logger.info("Started %s Docling worker(s)", _worker_count)
    try:
        yield
    finally:
        for worker in workers:
            worker.cancel()
        await asyncio.gather(*workers, return_exceptions=True)

app = FastAPI(
    title="Docling Ingestion Service",
    version="0.2.0",
    description=(
        "Private REST endpoint that converts PDFs to Markdown and basic layout"
        " metadata using Docling. Backed by a small in-process worker pool."
    ),
    lifespan=lifespan,
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
_TERMINAL_STATES = {"completed", "failed", "cancelled"}

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


async def _worker_loop(worker_id: int) -> None:
    """Background worker that consumes the queue with its own DocumentConverter."""
    converter = DocumentConverter(
        allowed_formats=[InputFormat.PDF],
        format_options={
            InputFormat.PDF: PdfFormatOption(
                pipeline_options=ThreadedPdfPipelineOptions(
                    generate_parsed_pages=True,
                    document_timeout=_conversion_timeout,
                )
            )
        },
    )
    logger.info("Worker %s ready", worker_id)

    while True:
        job: ConversionJob = await JOB_QUEUE.get()
        if job.state == "cancelled":
            JOB_QUEUE.task_done()
            continue

        job.state = "running"
        job.progress = 0.0
        job.started_at = time.perf_counter()
        job.timeout_at = job.timeout_at or (job.started_at + _conversion_timeout)
        job.worker_id = worker_id
        job.device = decide_device("auto")

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
                _convert_source(converter, job),
                timeout=_conversion_timeout,
            )
            if job.state == "cancelled":
                continue
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
                    "result": job.result,
                },
            )
        except asyncio.TimeoutError:
            if job.state == "cancelled":
                continue
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
        except Exception as err:
            if job.state == "cancelled":
                continue
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


def _record_docling_progress(job: ConversionJob, event: ConversionProgressEvent) -> None:
    # The worker thread posts events back to the owning asyncio loop.
    if job.state != "running":
        return

    if isinstance(event, DocumentStartedProgress):
        _push_event(job, {"type": "docling_started"})
    elif isinstance(event, PhaseStartedProgress):
        stage = {
            ConversionPhase.INITIALIZE: 2,
            ConversionPhase.BUILD: 2,
            ConversionPhase.ASSEMBLE: 5,
            ConversionPhase.ENRICH: 5,
        }[event.phase]
        _push_event(job, {"type": "docling_phase", "stage": event.phase.value, "stage_seq": stage})
    elif isinstance(event, PageCompletedProgress):
        job.pages_total = event.total_pages
        job.pages_done = event.completed_pages
        job.pages_failed += int(not event.success)
        job.progress = _progress_from_pages(job.pages_done, job.pages_total)
        _push_event(
            job,
            {
                "type": "page_processed" if event.success else "page_failed",
                "page_number": event.page_no,
                "stage_seq": 5,
            },
        )
    elif isinstance(event, DocumentCompletedProgress):
        _push_event(
            job,
            {"type": "docling_completed", "conversion_status": event.status.value, "stage_seq": 5},
        )


async def _convert_source(converter: DocumentConverter, job: ConversionJob) -> Dict[str, Any]:
    loop = asyncio.get_running_loop()

    def on_progress(event: ConversionProgressEvent) -> None:
        loop.call_soon_threadsafe(_record_docling_progress, job, event)

    def convert() -> Dict[str, Any]:
        conversion = converter.convert(job.source, progress_callback=on_progress)
        if conversion.status not in {ConversionStatus.SUCCESS, ConversionStatus.PARTIAL_SUCCESS}:
            raise RuntimeError(f"Docling conversion ended with status {conversion.status.value}")

        document = conversion.document
        return {
            "success": True,
            "markdown": document.export_to_markdown(),
            "metadata": {
                "page_count": len(document.pages),
                "source_kind": job.source_kind,
                "has_tables": bool(document.tables),
            },
            "pages": _build_pages(conversion),
        }

    return await asyncio.to_thread(convert)


def _build_pages(conversion: ConversionResult) -> List[Dict[str, Any]]:
    document = conversion.document
    segments_by_page: Dict[int, List[Dict[str, Any]]] = {}
    for index, (item, _) in enumerate(document.iterate_items()):
        if not isinstance(item, DocItem):
            continue
        for provenance in item.prov:
            page = document.pages[provenance.page_no]
            bbox = provenance.bbox.to_top_left_origin(page.size.height).normalized(page.size)
            segments_by_page.setdefault(page.page_no, []).append(
                {
                    "index_in_doc": index,
                    "label": item.label.value,
                    "text": getattr(item, "text", ""),
                    "bbox": bbox.as_tuple(),
                    "data": [{"html_seq": item.export_to_html(doc=document)}]
                    if isinstance(item, TableItem) else [],
                }
            )

    pages_by_number = {page.page_no: page for page in conversion.pages}
    pages = []
    for page_no in sorted(document.pages):
        page = pages_by_number.get(page_no)
        cells = []
        if page and page.size:
            for cell in page.cells:
                bbox = cell.rect.to_bounding_box().to_top_left_origin(page.size.height)
                cells.append(
                    {
                        "text": cell.text,
                        "bbox": bbox.normalized(page.size).as_tuple(),
                        "ocr": cell.from_ocr,
                        "ocr_confidence": cell.confidence,
                    }
                )
        pages.append(
            {
                "page_number": page_no,
                "text": document.export_to_text(page_no=page_no),
                "markdown": document.export_to_markdown(page_no=page_no),
                "cells": cells,
                "segments": segments_by_page.get(page_no, []),
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


@app.delete("/jobs/{job_id}", summary="Cancel a queued or running job")
async def cancel_job(job_id: str) -> JSONResponse:
    job = JOB_STORE.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Job not found")

    if job.state not in _TERMINAL_STATES:
        if job.state == "queued" and job.cleanup_path:
            Path(job.cleanup_path).unlink(missing_ok=True)
        job.state = "cancelled"
        job.last_error = "Docling conversion cancelled"
        job.error_status = 409
        job.finished_at = _now()
        _push_event(job, {"type": "cancelled", "message": job.last_error})
        if job.future and not job.future.done():
            job.future.set_result(None)

    return JSONResponse(content=_job_status(job))


@app.get("/jobs/{job_id}/stream", summary="Stream job events (SSE)")
async def job_stream(job_id: str) -> StreamingResponse:
    job = JOB_STORE.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")

    async def event_generator():
        queue = _subscribe(job)
        history = tuple(job.events)
        try:
            # Replay historical events
            for event in history:
                yield _format_sse(event)
                if event["state"] in _TERMINAL_STATES:
                    return

            # Stream new events with heartbeat
            while True:
                try:
                    event = await asyncio.wait_for(queue.get(), timeout=30.0)
                    yield _format_sse(event)
                    if event["state"] in _TERMINAL_STATES:
                        return
                except asyncio.TimeoutError:
                    # Send heartbeat to keep connection alive
                    yield _format_sse({"type": "heartbeat", "timestamp": time.time()})
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
