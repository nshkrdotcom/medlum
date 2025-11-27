defmodule Lumainus.Conversion.Backend do
  @moduledoc """
  Behavior for conversion backends.

  All backends (LocalBackend, CloudBackend) implement this behavior
  to provide a consistent API for:

  - Enqueueing conversion jobs
  - Awaiting job completion
  - Checking job status
  - Cancelling jobs
  - Health checks

  ## Implementation Guidelines

  1. **Never retry enqueue/2** — It creates duplicate jobs
  2. **Record provenance** — Store endpoint and instance_id in job metadata
  3. **Emit telemetry** — Use Telemetry.Emitter for all operations
  4. **Honor timeouts** — Respect timeout_ms options
  """

  @type job_ref :: %{
          job_id: String.t(),
          timeout_ms: pos_integer(),
          timeout_at: DateTime.t(),
          backend: module(),
          metadata: map()
        }

  @type enqueue_result :: {:ok, map()} | {:error, term()}
  @type status_result :: {:ok, map()} | {:error, term()}
  @type await_result :: {:ok, map()} | {:error, term()}
  @type health_result :: {:ok, map()} | {:error, term()}

  @doc """
  Enqueue a file for async conversion.

  Returns job reference on success. MUST NOT be retried.
  """
  @callback enqueue(binary :: binary(), opts :: keyword()) :: enqueue_result()

  @doc """
  Await job completion with progress callbacks.

  ## Options

  - `:timeout_ms` — Override default timeout
  - `:on_status` — Callback for progress updates
  - `:poll_interval_ms` — Polling interval (default: 250)
  """
  @callback await(job_ref(), opts :: keyword()) :: await_result()

  @doc """
  Get job status without blocking.
  """
  @callback status(job_id :: String.t()) :: status_result()

  @doc """
  Cancel a running job.
  """
  @callback cancel(job_id :: String.t()) :: :ok | {:error, term()}

  @doc """
  Check backend health.

  Should be quick (timeout 10-20s depending on backend type).
  """
  @callback health() :: health_result()

  @doc """
  Return backend name atom (e.g., :docker_cpu, :cloud).
  """
  @callback name() :: atom()

  @doc """
  Return backend type for metrics (:local or :cloud).
  """
  @callback backend_type() :: :local | :cloud
end
