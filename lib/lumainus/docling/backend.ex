defmodule Lumainus.Docling.Backend do
  @moduledoc """
  Behaviour for Docling conversion backends.

  Implement this behaviour to add support for new Docling deployment targets
  (local, remote HTTP, cloud GPU, etc.).

  ## Usage

  Backends are selected via configuration:

      config :lumainus, :docling,
        backend: :local  # or :remote, :vast_ai

  The facade module `Lumainus.Docling` automatically routes calls to the
  configured backend.

  ## Implementing a Backend

      defmodule MyBackend do
        @behaviour Lumainus.Docling.Backend

        @impl true
        def convert(binary, opts) do
          # Synchronous conversion
        end

        @impl true
        def enqueue(binary, opts) do
          # Async job submission
        end

        # ... etc
      end
  """

  @type convert_opts :: [
          filename: String.t(),
          content_type: String.t(),
          byte_size: non_neg_integer(),
          timeout_ms: non_neg_integer(),
          job_id: String.t(),
          upload_id: String.t()
        ]

  @type job :: %{
          job_id: String.t(),
          timeout_ms: non_neg_integer(),
          timeout_at: DateTime.t(),
          backend: module(),
          metadata: map()
        }

  @type await_opts :: [
          on_status: (map() -> :ok),
          poll_interval_ms: non_neg_integer()
        ]

  @type result :: {:ok, map()} | {:error, term()}

  @doc """
  Convert a PDF binary to markdown synchronously.

  This is the simplest API - blocks until conversion completes or times out.

  ## Options
    * `:filename` - Required. The filename for the upload.
    * `:content_type` - Content type (default: "application/pdf")
    * `:byte_size` - Size in bytes
    * `:timeout_ms` - Request timeout in milliseconds
    * `:job_id` - Optional job ID to associate

  ## Returns
    * `{:ok, result}` - Result map containing "markdown", "metadata", etc.
    * `{:error, reason}` - Error tuple
  """
  @callback convert(binary :: binary(), opts :: convert_opts()) :: result()

  @doc """
  Enqueue a conversion job asynchronously.

  Returns immediately with a job handle that can be passed to `await/2`.

  ## Options
    * `:filename` - Required. The filename for the upload.
    * `:content_type` - Content type (default: "application/pdf")
    * `:byte_size` - Size in bytes
    * `:timeout_ms` - Request timeout in milliseconds
    * `:job_id` - Optional job ID to use

  ## Returns
    * `{:ok, job}` - Job handle for use with `await/2`
    * `{:error, reason}` - Error tuple
  """
  @callback enqueue(binary :: binary(), opts :: convert_opts()) :: {:ok, job()} | {:error, term()}

  @doc """
  Await completion of a queued job.

  Blocks until the job completes, fails, or times out.

  ## Options
    * `:on_status` - Callback function invoked with status updates
    * `:poll_interval_ms` - Polling interval for fallback (default: 250)

  ## Returns
    * `{:ok, result}` - Result map containing "markdown", "metadata", etc.
    * `{:error, reason}` - Error tuple
  """
  @callback await(job :: job(), opts :: await_opts()) :: result()

  @doc """
  Check backend health and availability.

  ## Returns
    * `{:ok, status}` - Health status map
    * `{:error, reason}` - Error tuple
  """
  @callback health() :: {:ok, map()} | {:error, term()}

  @doc """
  Cancel a running job (best effort).

  Not all backends support cancellation. Check `capabilities/0` for support.

  ## Returns
    * `:ok` - Job cancelled or already complete
    * `{:error, :not_found}` - Job not found
    * `{:error, :not_supported}` - Backend doesn't support cancellation
    * `{:error, reason}` - Other error
  """
  @callback cancel(job_id :: String.t()) :: :ok | {:error, term()}

  @doc """
  Return backend capabilities.

  Capabilities indicate what features the backend supports:
    * `:sync` - Synchronous conversion via `convert/2`
    * `:async` - Asynchronous conversion via `enqueue/2` + `await/2`
    * `:sse` - Server-sent events for progress streaming
    * `:cancel` - Job cancellation
    * `:gpu` - GPU acceleration
    * `:auto_provision` - Automatic infrastructure provisioning

  ## Returns
    * List of capability atoms
  """
  @callback capabilities() :: [atom()]

  @optional_callbacks [cancel: 1, capabilities: 0]
end
