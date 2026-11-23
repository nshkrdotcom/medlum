"""
Tests for SSE streaming endpoint /jobs/{job_id}/stream
"""

import asyncio
import json
import time

import app.main as main
import pytest
import pytest_asyncio
from app.main import ConversionJob, _format_sse
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient


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


class TestSSEStream:
    """Tests for GET /jobs/{job_id}/stream endpoint."""

    @pytest.mark.asyncio
    async def test_stream_returns_404_for_missing_job(self, client):
        """SSE endpoint returns 404 for non-existent job."""
        response = await client.get("/jobs/nonexistent-job-id/stream")
        assert response.status_code == 404
        assert "not found" in response.json()["detail"].lower()

    @pytest.mark.asyncio
    async def test_stream_replays_historical_events_and_closes(self, client):
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
        main.JOB_STORE[job_id] = job
        response = await asyncio.wait_for(
            client.get(f"/jobs/{job_id}/stream"), timeout=2
        )
        assert response.status_code == 200
        events = [
            json.loads(line[6:])
            for line in response.text.splitlines()
            if line.startswith("data: ")
        ]
        assert [event["type"] for event in events] == ["queued", "started", "completed"]
        assert not job.subscribers

    @pytest.mark.asyncio
    async def test_cancel_running_job_streams_terminal_event(self, client):
        job = ConversionJob(
            id="cancel-test",
            source="/tmp/fake.pdf",
            source_kind="upload",
            upload_size=123,
            output_markdown=True,
            state="running",
        )
        main.JOB_STORE[job.id] = job
        response = await client.delete(f"/jobs/{job.id}")
        assert response.json()["state"] == "cancelled"
        stream = await asyncio.wait_for(client.get(f"/jobs/{job.id}/stream"), timeout=2)
        assert "event: cancelled" in stream.text
        assert not job.subscribers

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
        main.JOB_STORE["heartbeat-test-job"] = job

        queue = main._subscribe(job)

        try:
            received_heartbeat = False

            try:
                await asyncio.wait_for(queue.get(), timeout=0.1)
            except asyncio.TimeoutError:
                # Heartbeat sent on idle timeout
                heartbeat = main._format_sse(
                    {"type": "heartbeat", "timestamp": time.time()}
                )
                received_heartbeat = "heartbeat" in heartbeat

            assert received_heartbeat, "Expected heartbeat event on idle timeout"
        finally:
            main._unsubscribe(job, queue)
            del main.JOB_STORE["heartbeat-test-job"]


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
