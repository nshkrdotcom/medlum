defmodule Medlum.Documents.IngestionConfigTest do
  use ExUnit.Case, async: true

  alias Medlum.Documents.IngestionConfig

  describe "conversion_timeout_ms/0" do
    test "returns configured value from application env" do
      original = Application.get_env(:medlum, :ingestion)

      Application.put_env(:medlum, :ingestion, conversion_timeout_ms: 600_000)

      assert IngestionConfig.conversion_timeout_ms() == 600_000

      # Restore
      if original do
        Application.put_env(:medlum, :ingestion, original)
      else
        Application.delete_env(:medlum, :ingestion)
      end
    end

    test "returns default 20 minutes when not configured" do
      original = Application.get_env(:medlum, :ingestion)
      Application.delete_env(:medlum, :ingestion)

      assert IngestionConfig.conversion_timeout_ms() == 1_200_000

      # Restore
      if original, do: Application.put_env(:medlum, :ingestion, original)
    end
  end

  describe "max_retries/0" do
    test "returns configured value" do
      original = Application.get_env(:medlum, :ingestion)

      Application.put_env(:medlum, :ingestion, max_retries: 5)

      assert IngestionConfig.max_retries() == 5

      if original do
        Application.put_env(:medlum, :ingestion, original)
      else
        Application.delete_env(:medlum, :ingestion)
      end
    end

    test "returns default 3 when not configured" do
      original = Application.get_env(:medlum, :ingestion)
      Application.delete_env(:medlum, :ingestion)

      assert IngestionConfig.max_retries() == 3

      if original, do: Application.put_env(:medlum, :ingestion, original)
    end
  end

  describe "retry_backoff_ms/1" do
    test "calculates exponential backoff" do
      assert IngestionConfig.retry_backoff_ms(1) == 30_000
      assert IngestionConfig.retry_backoff_ms(2) == 60_000
      assert IngestionConfig.retry_backoff_ms(3) == 120_000
      assert IngestionConfig.retry_backoff_ms(4) == 240_000
    end

    test "caps at max 5 minutes" do
      # Very high attempt number should still cap at 300_000
      assert IngestionConfig.retry_backoff_ms(100) == 300_000
    end

    test "is always positive" do
      for attempt <- 1..20 do
        assert IngestionConfig.retry_backoff_ms(attempt) > 0
      end
    end
  end

  describe "max_file_size_bytes/0" do
    test "returns configured value" do
      original = Application.get_env(:medlum, :ingestion)

      Application.put_env(:medlum, :ingestion, max_file_size_bytes: 100_000_000)

      assert IngestionConfig.max_file_size_bytes() == 100_000_000

      if original do
        Application.put_env(:medlum, :ingestion, original)
      else
        Application.delete_env(:medlum, :ingestion)
      end
    end

    test "returns default 50 MB when not configured" do
      original = Application.get_env(:medlum, :ingestion)
      Application.delete_env(:medlum, :ingestion)

      assert IngestionConfig.max_file_size_bytes() == 50_000_000

      if original, do: Application.put_env(:medlum, :ingestion, original)
    end
  end

  describe "max_pages/0" do
    test "returns default 1000 when not configured" do
      original = Application.get_env(:medlum, :ingestion)
      Application.delete_env(:medlum, :ingestion)

      assert IngestionConfig.max_pages() == 1000

      if original, do: Application.put_env(:medlum, :ingestion, original)
    end
  end

  describe "stale_job_threshold_minutes/0" do
    test "returns default 60 when not configured" do
      original = Application.get_env(:medlum, :ingestion)
      Application.delete_env(:medlum, :ingestion)

      assert IngestionConfig.stale_job_threshold_minutes() == 60

      if original, do: Application.put_env(:medlum, :ingestion, original)
    end
  end

  describe "archive_after_days/0" do
    test "returns default 7 when not configured" do
      original = Application.get_env(:medlum, :ingestion)
      Application.delete_env(:medlum, :ingestion)

      assert IngestionConfig.archive_after_days() == 7

      if original, do: Application.put_env(:medlum, :ingestion, original)
    end
  end

  describe "deadline_from_now/0" do
    test "returns DateTime 20 minutes from now by default" do
      deadline = IngestionConfig.deadline_from_now()

      now = DateTime.utc_now()
      diff = DateTime.diff(deadline, now, :second)

      # Should be close to 1200 seconds (20 min)
      assert diff >= 1195 and diff <= 1205
    end
  end

  describe "calculate_deadline/1" do
    test "calculates deadline based on timeout and retries" do
      # With 3 retries and 60s timeout, deadline should account for all attempts
      deadline = IngestionConfig.calculate_deadline(timeout_ms: 60_000, max_retries: 3)

      now = DateTime.utc_now()
      diff = DateTime.diff(deadline, now, :second)

      # 3 attempts × 60s = 180s, plus some buffer
      # With backoff: 60 + 60 + 30 (backoff) + 60 + 60 (backoff) + 60 = ~330s
      # Just verify it's reasonable
      assert diff > 180 and diff < 600
    end
  end
end
