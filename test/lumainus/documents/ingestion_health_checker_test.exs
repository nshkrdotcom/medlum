defmodule Lumainus.Documents.IngestionHealthCheckerTest do
  use Lumainus.DataCase, async: false

  alias Lumainus.Documents.IngestionHealthChecker

  describe "start_link/1" do
    test "starts the GenServer" do
      assert {:ok, pid} =
               IngestionHealthChecker.start_link(
                 name: :ingestion_health_checker_test,
                 docling_health_fun: fn -> {:ok, %{}} end
               )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "check_health/0" do
    test "runs health check without errors" do
      {:ok, pid} =
        IngestionHealthChecker.start_link(
          name: :ingestion_health_checker_check_test,
          docling_health_fun: fn -> {:ok, %{}} end
        )

      # Should not raise
      assert :ok = IngestionHealthChecker.check_health(:ingestion_health_checker_check_test)

      GenServer.stop(pid)
    end
  end

  describe "get_status/0" do
    test "returns health status" do
      {:ok, pid} =
        IngestionHealthChecker.start_link(
          name: :ingestion_health_checker_status_test,
          docling_health_fun: fn -> {:ok, %{}} end
        )

      status = IngestionHealthChecker.get_status(:ingestion_health_checker_status_test)

      assert is_map(status)
      assert Map.has_key?(status, :last_check)
      assert Map.has_key?(status, :docling_healthy)

      GenServer.stop(pid)
    end
  end
end
