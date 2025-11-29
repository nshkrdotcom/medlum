defmodule Lumainus.Conversion.Service do
  @moduledoc """
  Public API for document conversion.

  ## Usage

      # Submit a job
      {:ok, job} = Service.submit(pdf_binary,
        filename: "report.pdf",
        profile: :enhanced,
        user_id: user.id,
        tenant_id: tenant.id
      )

      # Check status
      {:ok, status} = Service.status(job.id)

      # Await completion with progress
      {:ok, result} = Service.await(job.id,
        timeout_ms: 300_000,
        on_progress: fn status -> IO.puts(status.progress) end
      )

      # Cancel a job
      :ok = Service.cancel(job.id)

      # Check profile availability
      true = Service.available?(:enhanced)

  ## Critical Rules

  1. **NO RETRIES ON ENQUEUE** — The `submit/2` function does NOT retry
     the backend enqueue call because it's not idempotent.

  2. **Provenance Tracking** — Every job stores `backend_used`,
     `backend_endpoint`, and optionally `instance_id`.
  """

  alias Lumainus.Conversion.{Events, Job, JobStatus, Policy, ProcessingProfile}
  alias Lumainus.Conversion.Application.JobTracker
  alias Lumainus.Conversion.Infrastructure.BackendRouter
  alias Lumainus.Conversion.Infrastructure.Telemetry.Emitter

  require Logger

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Submit a file for conversion.

  ## Options

  - `:filename` (required) — Original filename
  - `:profile` — :standard (default) or :enhanced
  - `:content_type` — MIME type (default: "application/pdf")
  - `:user_id` — Submitting user ID
  - `:tenant_id` — Organization ID
  - `:timeout_ms` — Custom timeout (capped at profile max)
  - `:metadata` — Additional metadata map

  ## Returns

  - `{:ok, Job.t()}` — Job submitted successfully
  - `{:error, :file_too_large}` — File exceeds 100MB
  - `{:error, :invalid_content_type}` — Not a PDF
  - `{:error, :profile_not_available}` — User can't access profile
  - `{:error, :service_unavailable}` — No backends available
  """
  @spec submit(binary(), keyword()) :: {:ok, Job.t()} | {:error, term()}
  def submit(binary, opts) when is_binary(binary) do
    profile = Keyword.get(opts, :profile, :standard)
    router_fn = Keyword.get(opts, :backend_router_fn, &default_router/1)
    tracker = Keyword.get(opts, :job_tracker, JobTracker)

    with :ok <- Policy.validate_file(binary, opts),
         :ok <- validate_profile_access(opts, profile),
         {:ok, backend} <- router_fn.(profile),
         {:ok, job} <- create_and_persist_job(binary, opts, profile, backend, tracker),
         {:ok, _response} <- enqueue_to_backend(job, binary, backend) do
      Events.broadcast_submitted(job)
      Emitter.emit_job_submitted(job)
      {:ok, job}
    end
  end

  @doc """
  Get current status of a job.

  ## Returns

  - `{:ok, JobStatus.t()}` — Current status
  - `{:error, :not_found}` — Job doesn't exist
  """
  @spec status(String.t(), keyword()) :: {:ok, JobStatus.t()} | {:error, :not_found}
  def status(job_id, opts \\ []) when is_binary(job_id) do
    tracker = Keyword.get(opts, :job_tracker, JobTracker)

    with {:ok, job} <- JobTracker.get(tracker, job_id) do
      {:ok, JobStatus.from_job(job)}
    end
  end

  @doc """
  Await job completion with progress callbacks.

  ## Options

  - `:timeout_ms` — Override timeout (default: job's timeout_at)
  - `:on_progress` — Function called on each progress update

  ## Returns

  - `{:ok, result}` — Conversion result map
  - `{:error, :timeout}` — Job timed out
  - `{:error, :not_found}` — Job doesn't exist
  - `{:error, {:failed, reason}}` — Conversion failed
  """
  @spec await(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def await(job_id, opts \\ []) when is_binary(job_id) do
    tracker = Keyword.get(opts, :job_tracker, JobTracker)

    with {:ok, job} <- JobTracker.get(tracker, job_id) do
      backend_module = backend_module_for(job.backend_used)
      on_progress = Keyword.get(opts, :on_progress, fn _ -> :ok end)

      timeout_ms = remaining_timeout(job, opts)

      wrapped_progress = fn backend_status ->
        normalized = JobStatus.normalize_state(backend_status["state"])
        progress = normalize_progress(backend_status["progress"])

        Events.broadcast_progress(job, progress)

        # Emit telemetry at 10% intervals (check integer part)
        if rem(trunc(progress), 10) == 0 do
          Emitter.emit_job_progress(job, progress)
        end

        JobTracker.update(tracker, job_id, %{
          state: normalized,
          progress: progress,
          pages_done: backend_status["pages_done"],
          pages_total: backend_status["pages_total"]
        })

        status = JobStatus.from_job(Map.merge(job, %{state: normalized, progress: progress}))
        on_progress.(status)
      end

      job_ref = job_to_backend_ref(job)

      case backend_module.await(job_ref,
             timeout_ms: timeout_ms,
             on_status: wrapped_progress,
             endpoint: job.backend_endpoint
           ) do
        {:ok, result} ->
          {:ok, updated_job} =
            JobTracker.update(tracker, job_id, %{state: :completed, result: result})

          Events.broadcast_completed(updated_job)
          Emitter.emit_job_completed(updated_job)
          {:ok, result}

        {:error, :timeout} ->
          {:ok, updated_job} = JobTracker.update(tracker, job_id, %{state: :timeout})
          Events.broadcast_failed(updated_job, :timeout)
          Emitter.emit_job_failed(updated_job, :timeout)
          {:error, :timeout}

        {:error, {:job_failed, reason}} ->
          {:ok, updated_job} =
            JobTracker.update(tracker, job_id, %{state: :failed, last_error: inspect(reason)})

          Events.broadcast_failed(updated_job, reason)
          Emitter.emit_job_failed(updated_job, :docling_failed)
          {:error, {:failed, reason}}

        {:error, reason} ->
          {:ok, updated_job} =
            JobTracker.update(tracker, job_id, %{state: :failed, last_error: inspect(reason)})

          Events.broadcast_failed(updated_job, reason)
          Emitter.emit_job_failed(updated_job, :unknown)
          {:error, reason}
      end
    end
  end

  @doc """
  Cancel a running job.
  """
  @spec cancel(String.t(), keyword()) :: :ok | {:error, term()}
  def cancel(job_id, opts \\ []) when is_binary(job_id) do
    tracker = Keyword.get(opts, :job_tracker, JobTracker)

    with {:ok, job} <- JobTracker.get(tracker, job_id),
         backend_module = backend_module_for(job.backend_used),
         :ok <- backend_module.cancel(job_id, endpoint: job.backend_endpoint) do
      {:ok, updated_job} = JobTracker.update(tracker, job_id, %{state: :cancelled})
      Events.broadcast_cancelled(updated_job)
      Emitter.emit_job_cancelled(updated_job)
      :ok
    end
  end

  @doc """
  Check if a profile is currently available (backends healthy, breakers closed).
  """
  @spec available?(ProcessingProfile.t(), keyword()) :: boolean()
  def available?(profile, opts \\ []) do
    router_fn = Keyword.get(opts, :backend_router_fn, &default_router/1)

    case router_fn.(profile) do
      {:ok, _backend} -> true
      {:error, _} -> false
    end
  end

  @doc """
  List currently available profiles.
  """
  @spec profiles(keyword()) :: [ProcessingProfile.t()]
  def profiles(opts \\ []) do
    ProcessingProfile.all()
    |> Enum.filter(&available?(&1, opts))
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp default_router(profile) do
    BackendRouter.route(profile)
  end

  defp validate_profile_access(opts, profile) do
    user = Keyword.get(opts, :user, %{})

    if Policy.user_can_access_profile?(user, profile) do
      :ok
    else
      {:error, :profile_not_available}
    end
  end

  defp create_and_persist_job(binary, opts, profile, backend, tracker) do
    job_attrs = %{
      profile: profile,
      filename: Keyword.fetch!(opts, :filename),
      byte_size: byte_size(binary),
      tenant_id: Keyword.get(opts, :tenant_id),
      user_id: Keyword.get(opts, :user_id),
      timeout_ms: Keyword.get(opts, :timeout_ms),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    changeset =
      job_attrs
      |> Job.new()
      |> Ecto.Changeset.put_change(:backend_used, backend.name)
      |> Ecto.Changeset.put_change(:backend_endpoint, backend.endpoint)

    JobTracker.register(tracker, changeset)
  end

  defp enqueue_to_backend(job, binary, backend) do
    # NO RETRY HERE — enqueue is not idempotent
    backend.module.enqueue(binary,
      filename: job.filename,
      job_id: job.id,
      timeout_ms: DateTime.diff(job.timeout_at, DateTime.utc_now(), :millisecond),
      endpoint: backend.endpoint
    )
  end

  defp remaining_timeout(job, opts) do
    case Keyword.get(opts, :timeout_ms) do
      nil ->
        max(0, DateTime.diff(job.timeout_at, DateTime.utc_now(), :millisecond))

      override ->
        min(override, max(0, DateTime.diff(job.timeout_at, DateTime.utc_now(), :millisecond)))
    end
  end

  defp backend_module_for(:local_cpu), do: Lumainus.Conversion.Backends.LocalBackend
  defp backend_module_for(:local_gpu), do: Lumainus.Conversion.Backends.LocalBackend
  defp backend_module_for(:docker_cpu), do: Lumainus.Conversion.Backends.LocalBackend
  defp backend_module_for(:docker_gpu), do: Lumainus.Conversion.Backends.LocalBackend
  defp backend_module_for(:cloud), do: Lumainus.Conversion.Backends.CloudBackend
  defp backend_module_for(:test_backend), do: Lumainus.Conversion.Backends.LocalBackend
  defp backend_module_for(_), do: Lumainus.Conversion.Backends.LocalBackend

  defp job_to_backend_ref(job) do
    %{
      job_id: job.id,
      timeout_ms: max(0, DateTime.diff(job.timeout_at, DateTime.utc_now(), :millisecond)),
      backend: backend_module_for(job.backend_used),
      metadata: %{
        endpoint: job.backend_endpoint,
        instance_id: job.instance_id
      }
    }
  end

  defp normalize_progress(nil), do: 0.0

  defp normalize_progress(progress) when is_float(progress) do
    progress
    |> max(0.0)
    |> min(100.0)
    |> Float.round(2)
  end

  defp normalize_progress(progress) when is_integer(progress) do
    # Convert integer to float with 2 decimal places
    (progress * 1.0)
    |> max(0.0)
    |> min(100.0)
    |> Float.round(2)
  end

  defp normalize_progress(_), do: 0.0
end
