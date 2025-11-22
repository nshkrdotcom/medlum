defmodule Lumainus.Documents.IngestionHealthCheckerTest do
  use Lumainus.DataCase, async: false

  alias Lumainus.Documents.IngestionHealthChecker

  describe "start_link/1" do
    test "starts the GenServer" do
      assert {:ok, pid} = IngestionHealthChecker.start_link([])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "check_health/0" do
    test "runs health check without errors" do
      {:ok, pid} = IngestionHealthChecker.start_link([])

      # Should not raise
      assert :ok = IngestionHealthChecker.check_health()

      GenServer.stop(pid)
    end
  end

  describe "get_status/0" do
    test "returns health status" do
      {:ok, pid} = IngestionHealthChecker.start_link([])

      status = IngestionHealthChecker.get_status()

      assert is_map(status)
      assert Map.has_key?(status, :last_check)
      assert Map.has_key?(status, :docling_healthy)

      GenServer.stop(pid)
    end
  end
end
