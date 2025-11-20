"""FastAPI service exposing Docling PDF -> Markdown conversion."""

from __future__ import annotations

import asyncio
import logging
import os
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from fastapi import FastAPI, File, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from docling.document_converter import DocumentConverter
from docling.utils.export import generate_multimodal_pages

logger = logging.getLogger("docling_service")
logging.basicConfig(
    level=os.getenv("DOCLING_SERVICE_LOG_LEVEL", "INFO"),
    format="[%(asctime)s] %(levelname)s in %(name)s: %(message)s",
)

app = FastAPI(
    title="Docling Ingestion Service",
    version="0.1.0",
    description=(
        "Private REST endpoint that converts PDFs to Markdown and basic layout"
        " metadata using Docling."
    ),
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

_converter = DocumentConverter()
_converter_lock = asyncio.Lock()
_conversion_timeout = float(os.getenv("CONVERSION_TIMEOUT_SECONDS", "300"))


async def _convert_source(source: str, source_kind: str) -> Dict[str, Any]:
    """Run Docling conversion in a worker thread under a lock."""

    def _sync_convert() -> Dict[str, Any]:
        conversion = _converter.convert(source)
        doc = conversion.document
        if doc is None:
            raise RuntimeError("Docling returned an empty document")

        markdown = doc.export_to_markdown()
        pages = _build_pages(conversion)
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

    async with _converter_lock:
        return await asyncio.to_thread(_sync_convert)


def _build_pages(conversion) -> List[Dict[str, Any]]:
    pages: List[Dict[str, Any]] = []
    for (
        text,
        markdown,
        _tokens,
        cells,
        segments,
        page,
    ) in generate_multimodal_pages(conversion):
        pages.append(
            {
                "page_number": getattr(page, "page_no", len(pages) + 1),
                "text": (text or "").strip(),
                "markdown": (markdown or "").strip(),
                "cells": cells,
                "segments": segments,
            }
        )

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


async def _persist_upload(upload: UploadFile) -> str:
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

    logger.info(
        "Docling request received (kind=%s, size=%s bytes, timeout=%ss)",
        source_kind,
        upload_size,
        _conversion_timeout,
    )
    started = time.perf_counter()

    try:
        result = await asyncio.wait_for(
            _convert_source(source_to_convert, source_kind),
            timeout=_conversion_timeout,
        )
    except asyncio.TimeoutError:
        elapsed = time.perf_counter() - started
        logger.error(
            "Docling conversion timed out after %.2fs (kind=%s, size=%s bytes)",
            elapsed,
            source_kind,
            upload_size,
        )
        raise HTTPException(status_code=504, detail="Docling conversion timed out")
    except Exception as err:  # pragma: no cover - surfaced to client
        elapsed = time.perf_counter() - started
        logger.exception(
          "Docling conversion failed after %.2fs (kind=%s, size=%s bytes)",
          elapsed,
          source_kind,
          upload_size,
        )
        raise HTTPException(status_code=500, detail=str(err)) from err
    finally:
        if temp_path and os.path.exists(temp_path):
            os.unlink(temp_path)
    logger.info(
        "Docling conversion completed in %.2fs (kind=%s, size=%s bytes)",
        time.perf_counter() - started,
        source_kind,
        upload_size,
    )

    if not output_markdown:
        result.pop("markdown", None)

    return JSONResponse(content=result)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host=os.getenv("HOST", "0.0.0.0"),
        port=int(os.getenv("PORT", "8042")),
        reload=os.getenv("RELOAD", "false").lower() == "true",
    )
