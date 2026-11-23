defmodule Medlum.Documents.DoclingIngestionWorker do
  @moduledoc """
  Oban worker responsible for running Docling ingestion for uploads.

  Features:
  - Circuit breaker logic to prevent retries when deadline passed
  - Error history tracking for debugging
  - Cancellation support
  - Proper timeout handling with Task supervision
  """

  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 3,
    priority: 1

  alias Medlum.Documents
  alias Medlum.Documents.{IngestionConfig, IngestionJob, IngestionProcessor}
  alias Medlum.Repo

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ingestion_job_id" => job_id}, attempt: attempt, id: oban_id}) do
    job = Repo.get!(IngestionJob, job_id) |> Repo.preload(upload: [:patient, :record_set])

    # Link Oban job ID for cancellation support
    if is_nil(job.oban_job_id) do
      Documents.link_oban_job(job, oban_id)
    end

    upload = job.upload
    filename = (upload && upload.filename) || "unknown"
    upload_id = (upload && upload.id) || "unknown"
    job_backend = job.backend || "unknown"
    metadata_backend = get_in(job.metadata || %{}, ["backend"]) || "unknown"
    requested_backend = get_in(job.metadata || %{}, ["requested_backend"])

    Logger.info(
      "[DoclingIngestionWorker] STARTING job_id=#{job_id} oban_id=#{oban_id} " <>
        "upload_id=#{upload_id} filename=#{filename} attempt=#{attempt}/#{job.max_attempts} " <>
        "job_backend=#{job_backend} metadata_backend=#{metadata_backend} " <>
        "requested_backend=#{inspect(requested_backend)} state=#{job.state} stage=#{job.stage}"
    )

    # Check circuit breaker conditions
    case check_circuit_breaker(job, attempt) do
      :ok ->
        process_with_timeout(job, attempt)

      {:cancel, reason} = result ->
        Logger.warning(
          "[DoclingIngestionWorker] CANCELLED job_id=#{job_id} upload_id=#{upload_id} " <>
            "filename=#{filename} reason=#{inspect(reason)}"
        )

        result
    end
  end

  defp check_circuit_breaker(job, attempt) do
    cond do
      job.cancelled_at != nil ->
        {:cancel, :job_cancelled}

      deadline_exceeded?(job) ->
        Documents.mark_job_failed(job, "Hard deadline exceeded after #{attempt - 1} attempts")
        {:cancel, :deadline_exceeded}

      attempt > job.max_attempts ->
        Documents.mark_job_failed(job, "Max attempts (#{job.max_attempts}) exceeded")
        {:cancel, :max_attempts_exceeded}

      true ->
        :ok
    end
  end

  defp deadline_exceeded?(%{deadline_at: nil}), do: false

  defp deadline_exceeded?(%{deadline_at: deadline}) do
    DateTime.compare(DateTime.utc_now(), deadline) == :gt
  end

  defp process_with_timeout(job, attempt) do
    timeout_ms = IngestionConfig.conversion_timeout_ms()
    upload = job.upload
    filename = (upload && upload.filename) || "unknown"
    upload_id = (upload && upload.id) || "unknown"

    Logger.info(
      "[DoclingIngestionWorker] PROCESSING job_id=#{job.id} upload_id=#{upload_id} " <>
        "filename=#{filename} attempt=#{attempt}/#{job.max_attempts} " <>
        "timeout_ms=#{timeout_ms} backend=#{job.backend}"
    )

    # Mark job as processing and update attempt info
    {:ok, job} = Documents.mark_job_processing(job, attempt)

    # Run the processor in a supervised task with timeout
    task = Task.async(fn -> IngestionProcessor.process(job.id) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        Logger.info(
          "[DoclingIngestionWorker] COMPLETED job_id=#{job.id} upload_id=#{upload_id} " <>
            "filename=#{filename} backend=#{job.backend}"
        )

        :ok

      {:ok, {:error, reason}} ->
        handle_error(job, attempt, reason)

      nil ->
        # Task timed out
        handle_error(job, attempt, :timeout)

      {:exit, reason} ->
        handle_error(job, attempt, {:exit, reason})
    end
  end

  defp handle_error(job, attempt, reason) do
    Logger.error("Ingestion job #{job.id} failed on attempt #{attempt}: #{inspect(reason)}")

    # Record the error in history
    {:ok, job} = Documents.record_job_error(job, attempt, reason)

    # Check if we should retry
    if Documents.should_retry?(job) do
      # Return error to trigger Oban retry
      {:error, reason}
    else
      # No more retries - mark as failed
      error_message = format_error(reason)
      Documents.mark_job_failed(job, error_message)
      {:cancel, :no_more_retries}
    end
  end

  defp format_error(:timeout), do: "Processing timed out"
  defp format_error({:timeout, _}), do: "Processing timed out"
  defp format_error({:docling_failed, msg}) when is_binary(msg), do: msg
  defp format_error({:docling_failed, _}), do: "Docling processing failed"
  defp format_error({:http_error, status, _}), do: "HTTP error: #{status}"
  defp format_error({:exit, reason}), do: "Process crashed: #{inspect(reason)}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
