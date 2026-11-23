defmodule Medlum.Conversion.Infrastructure.ContextTest do
  use Medlum.Conversion.TestCase

  alias Medlum.Conversion.Infrastructure.Context

  describe "init/1" do
    test "creates context with generated IDs" do
      ctx = Context.init()

      assert is_binary(ctx.trace_id)
      assert is_binary(ctx.span_id)
      assert is_binary(ctx.correlation_id)
      assert String.length(ctx.trace_id) == 32
    end

    test "accepts custom trace_id" do
      ctx = Context.init(trace_id: "custom-trace")

      assert ctx.trace_id == "custom-trace"
    end

    test "accepts job_id, tenant_id, user_id" do
      job_id = Ecto.UUID.generate()
      tenant_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      ctx =
        Context.init(
          job_id: job_id,
          tenant_id: tenant_id,
          user_id: user_id
        )

      assert ctx.job_id == job_id
      assert ctx.tenant_id == tenant_id
      assert ctx.user_id == user_id
    end

    test "stores context in process dictionary" do
      _ctx = Context.init(trace_id: "stored-trace")

      # Should be retrievable via get/0
      retrieved = Context.get()
      assert retrieved.trace_id == "stored-trace"
    end
  end

  describe "get/0" do
    test "returns empty context when not initialized" do
      # In a clean process, should return empty struct
      ctx = Context.get()

      assert is_nil(ctx.trace_id)
      assert is_nil(ctx.span_id)
    end

    test "returns stored context" do
      Context.init(trace_id: "get-test", job_id: "job-123")

      ctx = Context.get()

      assert ctx.trace_id == "get-test"
      assert ctx.job_id == "job-123"
    end
  end

  describe "put/1" do
    test "updates context fields" do
      Context.init(trace_id: "original")
      Context.put(%{job_id: "new-job"})

      ctx = Context.get()

      assert ctx.trace_id == "original"
      assert ctx.job_id == "new-job"
    end

    test "returns updated context" do
      Context.init(trace_id: "original")

      result = Context.put(%{tenant_id: "tenant-456"})

      assert result.trace_id == "original"
      assert result.tenant_id == "tenant-456"
    end
  end

  describe "to_headers/0" do
    test "returns headers for HTTP propagation" do
      Context.init(
        trace_id: "trace-abc",
        span_id: "span-xyz",
        correlation_id: "corr-123",
        job_id: "job-456"
      )

      headers = Context.to_headers()

      assert {"x-trace-id", "trace-abc"} in headers
      assert {"x-span-id", "span-xyz"} in headers
      assert {"x-correlation-id", "corr-123"} in headers
      assert {"x-job-id", "job-456"} in headers
    end

    test "excludes nil or empty values" do
      Context.init(trace_id: "trace-only")

      headers = Context.to_headers()

      # Only trace_id, span_id, correlation_id should be present (auto-generated)
      assert length(headers) >= 1

      # job_id should not be in headers since it's nil
      refute Enum.any?(headers, fn {k, _} -> k == "x-job-id" end)
    end
  end

  describe "to_logger_metadata/0" do
    test "returns Logger metadata keyword list" do
      Context.init(
        trace_id: "trace-log",
        job_id: "job-log",
        tenant_id: "tenant-log",
        user_id: "user-log"
      )

      metadata = Context.to_logger_metadata()

      assert Keyword.get(metadata, :trace_id) == "trace-log"
      assert Keyword.get(metadata, :job_id) == "job-log"
      assert Keyword.get(metadata, :tenant_id) == "tenant-log"
      assert Keyword.get(metadata, :user_id) == "user-log"
    end

    test "excludes nil values" do
      Context.init(trace_id: "trace-only")

      metadata = Context.to_logger_metadata()

      # Should have trace_id, span_id, correlation_id
      assert Keyword.has_key?(metadata, :trace_id)

      # job_id should not be present
      refute Keyword.has_key?(metadata, :job_id)
    end
  end
end
