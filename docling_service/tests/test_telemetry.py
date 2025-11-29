import asyncio
import json
from typing import Optional

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from app import main


def reset_job_state():
    main.JOB_QUEUE = asyncio.Queue()
    main.JOB_STORE = {}


class FakeDocument:
    def export_to_markdown(self) -> str:
        return "# fake"


class FakeConversion:
    def __init__(self, pages):
        self.pages = pages
        self.document = FakeDocument()


class FakeConverter:
    def convert(self, _source, **_kwargs):
        return FakeConversion(pages=[1, 2])


def fake_generate_multimodal_pages(_conversion):
    for page_no in (1, 2):
        yield (f"text {page_no}", f"md {page_no}", None, [], [], type("Page", (), {"page_no": page_no}))


async def fake_slow_convert(_converter, _job, _source, _source_kind, progress_cb=None, docling_progress_cb=None):
    await asyncio.sleep(0.05)
    return None


@pytest.mark.asyncio
async def test_status_includes_progress(monkeypatch):
    reset_job_state()
    monkeypatch.setattr(main, "DocumentConverter", FakeConverter)
    monkeypatch.setattr(main, "generate_multimodal_pages", fake_generate_multimodal_pages)

    async with LifespanManager(main.app):
        transport = ASGITransport(app=main.app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.post(
                "/jobs",
                files={"file": ("doc.pdf", b"%PDF-1.4", "application/pdf")},
            )
            resp.raise_for_status()
            job_id = resp.json()["job_id"]

            status = {}
            for _ in range(40):
                await asyncio.sleep(0.02)
                status = (await client.get(f"/jobs/{job_id}/status")).json()
                if status["state"] in {"completed", "failed"}:
                    break

            assert status["state"] == "completed"
            assert status["pages_done"] == 2
            assert status["pages_total"] == 2
            assert status["progress"] == 100
            assert status["worker_id"] == 1
            assert status["device"] in {"cpu", "cuda"}


@pytest.mark.asyncio
async def test_events_recorded_in_job_store(monkeypatch):
    reset_job_state()
    monkeypatch.setattr(main, "DocumentConverter", FakeConverter)
    monkeypatch.setattr(main, "generate_multimodal_pages", fake_generate_multimodal_pages)

    async with LifespanManager(main.app):
        transport = ASGITransport(app=main.app)
        async with AsyncClient(transport=transport, base_url="http://test", timeout=5.0) as client:
            resp = await client.post(
                "/jobs",
                files={"file": ("doc.pdf", b"%PDF-1.4", "application/pdf")},
            )
            resp.raise_for_status()
            job_id = resp.json()["job_id"]

            for _ in range(40):
                await asyncio.sleep(0.02)
                status = (await client.get(f"/jobs/{job_id}/status")).json()
                if status["state"] in {"completed", "failed"}:
                    break

            job = main.JOB_STORE[job_id]
            event_types = [evt.get("type") for evt in job.events]

            assert "queued" in event_types
            assert "started" in event_types
            assert "page_processed" in event_types
            assert any(evt in {"completed", "failed"} for evt in event_types)


@pytest.mark.asyncio
async def test_timeout_emits_timeout(monkeypatch):
    reset_job_state()
    monkeypatch.setattr(main, "DocumentConverter", FakeConverter)
    monkeypatch.setattr(main, "_convert_source", fake_slow_convert)
    monkeypatch.setattr(main, "_conversion_timeout", 0.01)

    async with LifespanManager(main.app):
        transport = ASGITransport(app=main.app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.post(
                "/jobs",
                files={"file": ("doc.pdf", b"%PDF-1.4", "application/pdf")},
            )
            resp.raise_for_status()
            job_id = resp.json()["job_id"]

            status: Optional[dict] = None
            for _ in range(50):
                await asyncio.sleep(0.02)
                status = (await client.get(f"/jobs/{job_id}/status")).json()
                if status["state"] in {"failed", "completed"}:
                    break

            assert status is not None
            assert status["state"] == "failed"
            # Timeout path still sets progress to 100 in worker loop
            assert status["progress"] == 100
            # Check we saw a timeout/failed event recorded in the job
            job = main.JOB_STORE[job_id]
            event_types = [evt.get("type") for evt in job.events]
            assert "timeout" in event_types or "failed" in event_types
