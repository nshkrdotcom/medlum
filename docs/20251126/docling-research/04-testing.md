# Docling Testing Infrastructure

**Date:** November 26, 2025
**Component:** `test/lumainus/docling/`

---

## Executive Summary

The lumainus project has a well-structured testing infrastructure for Docling PDF-to-Markdown conversion. The tests are organized into unit tests, integration tests, and system-level tests, with extensive use of mocking via the Bypass library.

---

## 1. Test File Organization

### Core Docling Tests

```
test/lumainus/docling/
├── docling_test.exs                    # Main facade module tests
├── http_test.exs                       # HTTP client tests
├── health_check_worker_test.exs        # Health monitoring
├── backends/
│   ├── local_test.exs                  # Local backend tests
│   ├── remote_test.exs                 # Remote backend tests
│   └── vast_ai_test.exs                # Cloud GPU backend tests
└── vast_ai/
    └── instance_manager_test.exs       # Instance provisioning tests
```

### Related Document Processing Tests

```
test/lumainus/documents/
├── docling_ingestion_worker_test.exs   # Job processing worker
├── ingestion_processor_test.exs        # High-level ingestion pipeline
├── ingestion_job_lifecycle_test.exs    # Job state transitions
├── ingestion_health_checker_test.exs   # Ingestion health monitoring
└── ingestion_integration_test.exs      # End-to-end pipeline
```

---

## 2. Testing Patterns Used

### 2.1 Unit Tests (Individual Backend Tests)

**Files:** `docling_test.exs`, `http_test.exs`, `local_test.exs`, `remote_test.exs`, `vast_ai_test.exs`

**Pattern:**
- Use `ExUnit.Case` with Bypass for HTTP mocking
- Test individual backend operations in isolation
- Mock Docling service responses

**Example from `http_test.exs`:**
```elixir
describe "convert/3" do
  test "successfully converts PDF binary" do
    Bypass.expect_once(bypass, "POST", "/convert", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{
        "markdown" => "# Test Document\n\nSome content.",
        "metadata" => %{"page_count" => 1}
      }))
    end)

    pdf_binary = "%PDF-1.4 test content"
    opts = [filename: "test.pdf", content_type: "application/pdf"]

    assert {:ok, result} = HTTP.convert(pdf_binary, opts, base_url: base_url)
    assert result["markdown"] == "# Test Document\n\nSome content."
  end
end
```

### 2.2 Backend Configuration Tests

**File:** `docling_test.exs`

Tests the main `Lumainus.Docling` facade module:
- Backend resolution (`backend/0`)
- Configuration loading
- Capability detection
- URL validation (HTTPS enforcement for non-local URLs)

**Key test patterns:**
```elixir
test "returns configured backend" do
  original_config = Application.get_env(:lumainus, :docling, [])
  Application.put_env(:lumainus, :docling,
    Keyword.put(original_config, :backend, :remote))

  on_exit(fn ->
    Application.put_env(:lumainus, :docling, original_config)
  end)

  assert Docling.backend() == Lumainus.Docling.Backends.Remote
end
```

### 2.3 Integration Tests (Job Lifecycle)

**File:** `ingestion_job_lifecycle_test.exs`

Tests complete job state transitions:
- `mark_job_processing/2` - Transitions job to running state
- `mark_job_completed/1` - Marks successful completion
- `mark_job_failed/2` - Records failures
- `record_job_error/3` - Maintains error history
- `cancel_ingestion_job/1` - Cancellation logic
- `should_retry?/1` - Retry decision logic

### 2.4 System Integration Tests

**File:** `ingestion_integration_test.exs`

**Tags:**
```elixir
@moduletag :integration
@moduletag timeout: 300_000  # 5 minute timeout
@run_docling System.get_env("RUN_DOCLING_INTEGRATION") == "1"

if not @run_docling do
  @moduletag skip: "Set RUN_DOCLING_INTEGRATION=1 to run"
end
```

**Tests:**
- Queue system configuration
- Job creation with deadline calculation
- Job cancellation at various stages
- Error recording and retry logic

---

## 3. Mock/Stub Implementations

### 3.1 Bypass Library Usage

**Setup Pattern:**
```elixir
setup do
  bypass = Bypass.open()
  base_url = "http://localhost:#{bypass.port}"

  original_config = Application.get_env(:lumainus, :docling, [])
  Application.put_env(:lumainus, :docling,
    Keyword.put(original_config, :local_url, base_url))

  on_exit(fn ->
    Application.put_env(:lumainus, :docling, original_config)
  end)

  {:ok, bypass: bypass, base_url: base_url}
end
```

**Endpoint Expectations:**
- `POST /convert` - Synchronous conversion
- `POST /jobs` - Enqueue async job
- `GET /jobs/:job_id/status` - Check job status
- `GET /health` - Health check
- `DELETE /jobs/:job_id` - Cancel job

### 3.2 Function-Based Mocks (for Vast.ai)

```elixir
mock_provision = fn -> {:ok, "test-instance", endpoint} end
mock_destroy = fn _id -> :ok end

new_config = Keyword.put(original_config, :vast_ai,
  provisioner: mock_provision,
  destroyer: mock_destroy,
  api_key: "test-key"
)
```

### 3.3 Database Fixtures

```elixir
defp create_test_tenant do
  slug = "test-tenant-#{System.unique_integer([:positive])}"

  %Lumainus.Tenancy.Tenant{}
  |> Lumainus.Tenancy.Tenant.changeset(%{name: "Test Tenant", slug: slug})
  |> Repo.insert!()
end

defp create_test_job(tenant, upload, record_set, attrs \\ %{}) do
  base_attrs = %{
    tenant_id: tenant.id,
    upload_id: upload.id,
    record_set_id: record_set.id,
    job_type: "docling",
    status: "queued",
    state: "queued",
    stage: "queued",
    max_attempts: 3,
    attempt_number: 1
  }

  %IngestionJob{}
  |> IngestionJob.changeset(Map.merge(base_attrs, attrs))
  |> Repo.insert!()
end
```

---

## 4. ExUnit Test Tags and Configuration

### 4.1 Test Tags

**Async Control:**
```elixir
use ExUnit.Case, async: true   # HTTP tests (no shared state)
use ExUnit.Case, async: false  # Backend tests (Bypass port management)
```

**Logging:**
```elixir
@moduletag :capture_log  # Suppress log output in test results
```

**Integration Tests:**
```elixir
@moduletag :integration
@moduletag timeout: 300_000  # Override default timeout
@moduletag :slow
```

### 4.2 Test Configuration (config/test.exs)

```elixir
config :lumainus, :docling,
  queue_mode: :inline,  # Oban runs jobs inline
  default_mode: :local,
  active_local_backend: :docker_cpu,
  native_cpu_url: "http://127.0.0.1:8040",
  native_gpu_url: "http://127.0.0.1:8041",
  docker_cpu_url: "http://127.0.0.1:8042",
  docker_gpu_url: "http://127.0.0.1:8043",
  cloud_url: nil,
  timeout_ms: 1_200_000,
  request_timeout: 1_200_000,
  poll_interval_ms: 1_000,
  prefer_sse: false,
  suppress_logs: true,
  prefer_env_overrides: true
```

---

## 5. Backend Availability Handling in Tests

### 5.1 Strategy

1. **Bypass Mocking** - All HTTP backends use mocked responses
2. **Configuration Overrides** - Tests override URLs to point to Bypass servers
3. **GenServer Supervision** - VastAI InstanceManager is started in tests with `start_supervised!`

### 5.2 Error Path Testing

**Connection Failures:**
```elixir
test "returns error on connection refused" do
  bad_url = "http://localhost:59999"  # Non-listening port
  pdf_binary = "%PDF-1.4 test"
  opts = [filename: "test.pdf", timeout_ms: 1_000]

  assert {:error, _reason} = HTTP.convert(pdf_binary, opts, base_url: bad_url)
end
```

**HTTP Errors:**
```elixir
test "returns error on HTTP 500" do
  Bypass.expect_once(bypass, "POST", "/convert", fn conn ->
    Plug.Conn.resp(conn, 500, Jason.encode!(%{"error" => "Internal error"}))
  end)

  assert {:error, {:http_error, 500, _}} =
    HTTP.convert(pdf_binary, opts, base_url: base_url)
end
```

---

## 6. Identified Gaps in Test Coverage

### 6.1 Integration Test Execution

- **Gap:** Integration tests skipped in normal CI runs
- **Impact:** End-to-end conversion testing not automated
- **Mitigation:** Tests exist but must be run manually with `RUN_DOCLING_INTEGRATION=1`

### 6.2 SSE (Server-Sent Events) Testing

- **Gap:** Tests use `prefer_sse: false` globally
- **Impact:** SSE streaming is not tested
- **Recommendation:** Add SSE-specific tests with mock SSE responses

### 6.3 Network Resilience

- **Limited:** Only basic connection refused error is tested
- **Gap:** No tests for:
  - Partial failures (timeout after successful enqueue)
  - Network flakiness with retries
  - Large file handling (>100MB PDFs)

### 6.4 Backend Switching

- **Gap:** Limited tests for switching between backends at runtime
- **Recommendation:** Add tests for active backend switching and fallback

### 6.5 Concurrent Job Handling

- **Gap:** No tests for multiple simultaneous conversions
- **Recommendation:** Add stress tests with Task.async

### 6.6 Timeout Handling

- **Gap:** Placeholder test exists but not implemented:
  ```elixir
  @tag :slow
  test "records error on timeout" do
    # Placeholder; real timeout handled in integration tests
    assert true
  end
  ```

---

## 7. Recommendations for Improving Testability

### 7.1 Enhance Integration Test Coverage

```elixir
# Add a separate test suite for real Docling service
describe "with real Docling service" do
  @moduletag :integration
  @moduletag :requires_docling_service

  test "converts real PDF successfully" do
    # Test with actual Docling service
  end
end
```

### 7.2 Add SSE Testing

```elixir
test "streams progress via SSE" do
  Bypass.expect(bypass, "GET", "/jobs/job-1/stream", fn conn ->
    conn
    |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
    |> Plug.Conn.send_chunked(200)
    |> elem(1)
    |> Plug.Conn.chunk("data: {\"state\":\"running\",\"progress\":50}\n\n")
    |> elem(1)
    |> Plug.Conn.chunk("data: {\"state\":\"completed\"}\n\n")
  end)
end
```

### 7.3 Add Contract Tests

```elixir
test "backends implement required callbacks" do
  for backend <- Docling.all_backends() do
    module = Docling.backend_module(backend)
    assert function_exported?(module, :convert, 2)
    assert function_exported?(module, :enqueue, 2)
    assert function_exported?(module, :await, 2)
    assert function_exported?(module, :health, 0)
    assert function_exported?(module, :cancel, 1)
  end
end
```

### 7.4 Add Property-Based Tests

```elixir
# Use StreamData for property-based testing
property "job status transitions are valid" do
  forall state <- job_state_generator() do
    {:ok, updated} = Documents.mark_job_failed(state, "error")
    is_valid_transition?(state.state, updated.state)
  end
end
```

---

## 8. Summary Table: Test Coverage by Component

| Component | Test File | Coverage | Gaps |
|-----------|-----------|----------|------|
| **HTTP Client** | `http_test.exs` | Excellent | Missing SSE tests |
| **Local Backend** | `local_test.exs` | Good | Limited timeout scenarios |
| **Remote Backend** | `remote_test.exs` | Good | Configuration validation |
| **VastAI Backend** | `vast_ai_test.exs` | Good | Instance lifecycle edges |
| **Instance Manager** | `instance_manager_test.exs` | Good | Concurrent provisioning |
| **Job Lifecycle** | `ingestion_job_lifecycle_test.exs` | Excellent | - |
| **Ingestion Worker** | `docling_ingestion_worker_test.exs` | Good | Timeout handling |
| **Ingestion Processor** | `ingestion_processor_test.exs` | Good | Error recovery paths |
| **Health Checking** | `health_check_worker_test.exs` | Basic | Alerts/thresholds |
| **Integration** | `ingestion_integration_test.exs` | Good | Skipped in CI |
| **Facade** | `docling_test.exs` | Good | Backend switching |

---

## 9. Conclusion

### Strengths
- Comprehensive unit test coverage with Bypass mocking
- Well-organized test structure mirroring source code
- Good use of ExUnit patterns and tags
- Proper test configuration isolation
- Clear test fixtures and helpers

### Areas for Improvement
- Enable some integration tests in CI pipeline (with Docker)
- Add SSE/streaming tests
- Implement timeout and resilience tests
- Add property-based tests for state transitions
- Document test conventions

### Recommended Next Steps
1. Create a `TESTING.md` guide documenting test patterns
2. Add a separate CI job for integration tests with Docker
3. Implement SSE streaming tests
4. Add property-based tests using StreamData
5. Create performance baseline tests
