defmodule Medlum.Conversion.JobStatus do
  @moduledoc """
  Read-only view of job status, returned by status/1 and await/3.

  This is NOT persisted separately—it's constructed from Job + backend state.

  ## Usage

      {:ok, status} = Service.status(job_id)
      status.state       # :processing
      status.progress    # 50
      status.message     # "Converting document..."

  ## Fields

  - `job_id` — The job UUID
  - `state` — Canonical state atom
  - `progress` — 0-100 percentage
  - `message` — Human-readable status message
  - `pages_total` — Total pages (if known)
  - `pages_done` — Pages processed
  - `result` — Conversion result (when completed)
  - `error` — Error message (when failed)
  - `updated_at` — Last status update timestamp

  ## Provenance (for operators)

  - `backend_used` — Which backend processed this job
  - `backend_endpoint` — The endpoint URL
  - `instance_id` — Vast.ai instance ID (if cloud)
  - `processed_at` — Completion timestamp
  """

  require Logger

  alias Medlum.Conversion.Job

  @type state ::
          :queued
          | :provisioning
          | :starting
          | :processing
          | :completed
          | :failed
          | :cancelled
          | :timeout

  @type t :: %__MODULE__{
          job_id: String.t(),
          state: state(),
          progress: float(),
          message: String.t() | nil,
          pages_total: non_neg_integer() | nil,
          pages_done: non_neg_integer(),
          result: map() | nil,
          error: String.t() | nil,
          updated_at: DateTime.t() | nil,
          backend_used: atom() | nil,
          backend_endpoint: String.t() | nil,
          instance_id: integer() | nil,
          processed_at: DateTime.t() | nil
        }

  defstruct [
    :job_id,
    :state,
    :progress,
    :message,
    :pages_total,
    :pages_done,
    :result,
    :error,
    :updated_at,
    :backend_used,
    :backend_endpoint,
    :instance_id,
    :processed_at
  ]

  @doc """
  Build JobStatus from Job record.
  """
  @spec from_job(Job.t()) :: t()
  def from_job(%Job{} = job) do
    %__MODULE__{
      job_id: job.id,
      state: job.state,
      progress: job.progress || 0,
      message: state_message(job.state),
      pages_total: job.pages_total,
      pages_done: job.pages_done || 0,
      result: job.result,
      error: job.last_error,
      updated_at: job.updated_at,
      backend_used: job.backend_used,
      backend_endpoint: job.backend_endpoint,
      instance_id: job.instance_id,
      processed_at: if(job.state == :completed, do: job.updated_at)
    }
  end

  @doc """
  Normalize backend response state to our canonical states.

  Backend services may return different state strings. This function
  maps them to our canonical atoms.

  ## Examples

      iex> normalize_state("queued")
      :queued

      iex> normalize_state("loading")
      :provisioning

      iex> normalize_state("running")
      :processing

      iex> normalize_state("unknown")
      :processing
  """
  @spec normalize_state(String.t() | atom()) :: state()
  def normalize_state("queued"), do: :queued
  def normalize_state("loading"), do: :provisioning
  def normalize_state("starting"), do: :starting
  def normalize_state("running"), do: :processing
  def normalize_state("processing"), do: :processing
  def normalize_state("completed"), do: :completed
  def normalize_state("failed"), do: :failed
  def normalize_state("cancelled"), do: :cancelled
  def normalize_state("timeout"), do: :timeout

  def normalize_state(atom) when is_atom(atom), do: atom

  def normalize_state(unknown) when is_binary(unknown) do
    Logger.warning("[JobStatus] Unknown state: #{unknown}, treating as :processing")
    :processing
  end

  # State message mapping

  defp state_message(:queued), do: "Waiting in queue..."
  defp state_message(:provisioning), do: "Starting GPU instance..."
  defp state_message(:starting), do: "Initializing processor..."
  defp state_message(:processing), do: "Converting document..."
  defp state_message(:completed), do: "Conversion complete"
  defp state_message(:failed), do: "Conversion failed"
  defp state_message(:cancelled), do: "Cancelled"
  defp state_message(:timeout), do: "Timed out"
  defp state_message(_), do: "Processing..."
end
