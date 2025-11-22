defmodule Lumainus.Documents.IngestionConfig do
  @moduledoc """
  Centralized configuration for document ingestion timeouts, limits, and retry behavior.

  All ingestion-related configuration should be accessed through this module
  to ensure consistency across the system.
  """

  # 20 minutes
  @default_conversion_timeout_ms 1_200_000
  @default_max_retries 3
  # 50 MB
  @default_max_file_size_bytes 50_000_000
  @default_max_pages 1000
  @default_stale_job_threshold_minutes 60
  @default_archive_after_days 7
  # 5 minutes
  @max_backoff_ms 300_000

  @doc """
  Returns the conversion timeout in milliseconds.

  This is the maximum time allowed for a single conversion attempt.
  """
  def conversion_timeout_ms do
    get_config(:conversion_timeout_ms, @default_conversion_timeout_ms)
  end

  @doc """
  Returns the maximum number of retry attempts for a failed job.
  """
  def max_retries do
    get_config(:max_retries, @default_max_retries)
  end

  @doc """
  Calculates exponential backoff for retry attempts.

  Returns milliseconds to wait before the nth retry attempt.
  Backoff is capped at 5 minutes.

  ## Examples

      iex> IngestionConfig.retry_backoff_ms(1)
      30_000

      iex> IngestionConfig.retry_backoff_ms(2)
      60_000

      iex> IngestionConfig.retry_backoff_ms(3)
      120_000
  """
  def retry_backoff_ms(attempt) when is_integer(attempt) and attempt > 0 do
    backoff = trunc(30_000 * :math.pow(2, attempt - 1))
    min(backoff, @max_backoff_ms)
  end

  @doc """
  Returns the maximum allowed file size in bytes.
  """
  def max_file_size_bytes do
    get_config(:max_file_size_bytes, @default_max_file_size_bytes)
  end

  @doc """
  Returns the maximum number of pages allowed in a document.
  """
  def max_pages do
    get_config(:max_pages, @default_max_pages)
  end

  @doc """
  Returns the threshold in minutes after which a job is considered stale.

  Jobs in "processing" state longer than this will be marked as failed
  by the cleanup worker.
  """
  def stale_job_threshold_minutes do
    get_config(:stale_job_threshold_minutes, @default_stale_job_threshold_minutes)
  end

  @doc """
  Returns the number of days after which completed/failed jobs are archived.
  """
  def archive_after_days do
    get_config(:archive_after_days, @default_archive_after_days)
  end

  @doc """
  Returns a deadline DateTime based on the current configuration.

  This is a convenience function that calculates deadline_at for new jobs.
  """
  def deadline_from_now do
    timeout_seconds = div(conversion_timeout_ms(), 1000)
    DateTime.utc_now() |> DateTime.add(timeout_seconds, :second)
  end

  @doc """
  Calculates the hard deadline for a job considering all potential retries.

  This gives the absolute latest time a job should complete, accounting for
  all retry attempts and backoff delays.

  ## Options

    * `:timeout_ms` - Override the conversion timeout (default: from config)
    * `:max_retries` - Override max retries (default: from config)
  """
  def calculate_deadline(opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, conversion_timeout_ms())
    retries = Keyword.get(opts, :max_retries, max_retries())

    # Calculate total time: initial attempt + (retries × (backoff + timeout))
    initial_timeout = timeout_ms

    retry_time =
      Enum.reduce(1..retries, 0, fn attempt, acc ->
        backoff = retry_backoff_ms(attempt)
        acc + backoff + timeout_ms
      end)

    total_ms = initial_timeout + retry_time
    total_seconds = div(total_ms, 1000)

    # Add 10% buffer
    buffered_seconds = trunc(total_seconds * 1.1)

    DateTime.utc_now() |> DateTime.add(buffered_seconds, :second) |> DateTime.truncate(:second)
  end

  @doc """
  Returns the conversion timeout in seconds (for Python service compatibility).
  """
  def conversion_timeout_seconds do
    div(conversion_timeout_ms(), 1000)
  end

  @doc """
  Validates if a file size is within allowed limits.
  """
  def valid_file_size?(byte_size) when is_integer(byte_size) do
    byte_size > 0 and byte_size <= max_file_size_bytes()
  end

  @doc """
  Validates if a page count is within allowed limits.
  """
  def valid_page_count?(page_count) when is_integer(page_count) do
    page_count > 0 and page_count <= max_pages()
  end

  # Private helpers

  defp get_config(key, default) do
    Application.get_env(:lumainus, :ingestion, [])
    |> Keyword.get(key, default)
  end
end
