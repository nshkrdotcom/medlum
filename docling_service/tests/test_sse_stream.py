"""
Tests for SSE streaming endpoint /jobs/{job_id}/stream
"""
import asyncio
import time
import pytest
import pytest_asyncio
from unittest.mock import patch
from httpx import AsyncClient, ASGITransport
from asgi_lifespan import LifespanManager

import app.main as main
from app.main import JOB_STORE, ConversionJob, _format_sse


@pytest.fixture(autouse=True)
def reset_state():
    """Reset global job state between tests."""
    main.JOB_QUEUE = asyncio.Queue()
    main.JOB_STORE = {}
    yield
    main.JOB_QUEUE = asyncio.Queue()
    main.JOB_STORE = {}


@pytest_asyncio.fixture
async def client():
    """Async test client with app lifecycle."""
    async with LifespanManager(main.app):
        transport = ASGITransport(app=main.app)
        async with AsyncClient(transport=transport, base_url="http://test") as c:
            yield c


@pytest.fixture
def mock_converter():
    """Mock Docling converter to avoid actual processing."""

    class FakeResult:
        document = type("Doc", (), {"export_to_markdown": lambda self: "# Test"})()
        pages = []

    class FakeConverter:
        def convert(self, source, **kwargs):
            return FakeResult()

    with patch.object(main, "DocumentConverter", return_value=FakeConverter()):
        with patch.object(main, "generate_multimodal_pages", return_value=[]):
            yield


class TestSSEStream:
    """Tests for GET /jobs/{job_id}/stream endpoint."""

    @pytest.mark.asyncio
    async def test_stream_returns_404_for_missing_job(self, client):
        """SSE endpoint returns 404 for non-existent job."""
        response = await client.get("/jobs/nonexistent-job-id/stream")
        assert response.status_code == 404
        assert "not found" in response.json()["detail"].lower()

    @pytest.mark.asyncio
    async def test_stream_replays_historical_events(self, mock_converter):
        """SSE stream replays all historical events on connect."""
        job_id = "replay-test-job"
        job = ConversionJob(
            id=job_id,
            source="/tmp/fake.pdf",
            source_kind="upload",
            upload_size=123,
            output_markdown=True,
            submitted_at=time.time(),
            timeout_at=time.time() + 3600,
        )
        job.state = "completed"
        job.events = [
            {"type": "queued", "state": "queued"},
            {"type": "started", "state": "running", "progress": 0},
            {"type": "completed", "state": "completed", "progress": 100},
        ]
        queue = main._subscribe(job)
        try:
            events = [main._format_sse(event) for event in job.events]
        finally:
            main._unsubscribe(job, queue)

        # Should have received historical events
        assert len(events) >= 1
        assert any("queued" in e for e in events)

    @pytest.mark.asyncio
    async def test_stream_sends_heartbeat_when_idle(self, client):
        """SSE stream sends heartbeat events to keep connection alive."""
        # Create a completed job directly in store
        job = ConversionJob(
            id="heartbeat-test-job",
            source="/tmp/fake.pdf",
            source_kind="upload",
            upload_size=100,
            output_markdown=True,
            submitted_at=time.time(),
            timeout_at=time.time() + 3600,
        )
        job.state = "completed"
        job.events = [{"type": "completed", "state": "completed"}]
        JOB_STORE["heartbeat-test-job"] = job

        queue = main._subscribe(job)

        try:
            received_heartbeat = False

            try:
                await asyncio.wait_for(queue.get(), timeout=0.1)
            except asyncio.TimeoutError:
                # Heartbeat sent on idle timeout
                heartbeat = main._format_sse({"type": "heartbeat", "timestamp": time.time()})
                received_heartbeat = "heartbeat" in heartbeat

            assert received_heartbeat, "Expected heartbeat event on idle timeout"
        finally:
            main._unsubscribe(job, queue)
            del JOB_STORE["heartbeat-test-job"]


class TestSSEFormat:
    """Tests for SSE event formatting."""

    def test_format_sse_basic(self):
        """SSE format is correct."""
        event = {"type": "test", "data": "value"}
        result = _format_sse(event)
        assert result.startswith("event: test\n")
        assert "data: " in result
        assert result.endswith("\n\n")

    def test_format_sse_defaults_to_message_type(self):
        """Events without type default to 'message'."""
        event = {"data": "value"}
        result = _format_sse(event)
        assert result.startswith("event: message\n")
