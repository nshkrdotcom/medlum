import asyncio
from typing import Optional

import pytest
from app import main
from asgi_lifespan import LifespanManager
from docling.datamodel.base_models import ConversionStatus
from docling.datamodel.progress import PageCompletedProgress
from docling_core.types.doc import DoclingDocument, Size
from httpx import ASGITransport, AsyncClient


def reset_job_state():
    main.JOB_QUEUE = asyncio.Queue()
    main.JOB_STORE = {}


class FakeConversion:
    status = ConversionStatus.SUCCESS

    def __init__(self):
        self.pages = []
        self.document = DoclingDocument(name="fake")
        for page_no in (1, 2):
            self.document.add_page(page_no=page_no, size=Size(width=100, height=100))


class FakeConverter:
    def __init__(self, **_options):
        pass

    def convert(self, _source, *, progress_callback):
        # Out-of-order completion must still advance the count monotonically.
        for completed, page_no in enumerate((2, 1), start=1):
            progress_callback(
                PageCompletedProgress(
                    document_index=1,
                    document_name="fake.pdf",
                    page_no=page_no,
                    success=page_no == 2,
                    completed_pages=completed,
                    total_pages=2,
                )
            )
        return FakeConversion()


async def fake_slow_convert(_converter, _job):
    await asyncio.sleep(0.05)


@pytest.mark.asyncio
async def test_status_includes_progress(monkeypatch):
    reset_job_state()
    monkeypatch.setattr(main, "DocumentConverter", FakeConverter)

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
            assert status["pages_failed"] == 1
            assert status["progress"] == 100
            assert status["worker_id"] == 1
            assert status["device"] == main.decide_device("auto")


@pytest.mark.asyncio
async def test_events_recorded_in_job_store(monkeypatch):
    reset_job_state()
    monkeypatch.setattr(main, "DocumentConverter", FakeConverter)

    async with LifespanManager(main.app):
        transport = ASGITransport(app=main.app)
        async with AsyncClient(
            transport=transport, base_url="http://test", timeout=5.0
        ) as client:
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
            page_events = [
                event
                for event in job.events
                if event["type"] in {"page_processed", "page_failed"}
            ]
            assert [
                (event["page_number"], event["pages_done"], event["progress"])
                for event in page_events
            ] == [
                (2, 1, 50.0),
                (1, 2, 100.0),
            ]
            assert event_types[-1] == "completed"


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
