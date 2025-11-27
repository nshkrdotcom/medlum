defmodule Lumainus.Conversion.Job do
  @moduledoc """
  Represents a conversion job from submission to completion.

  ## Fields

  - `id` — UUID, primary key
  - `profile` — :standard | :enhanced
  - `filename` — Original filename for display and content-type inference
  - `byte_size` — File size in bytes
  - `tenant_id` — Organization/workspace identifier
  - `user_id` — Submitting user
  - `submitted_at` — UTC timestamp of submission
  - `timeout_at` — UTC timestamp when job should be considered timed out
  - `code_version` — :v2 (fixed at submit, enables future versioning)
  - `metadata` — JSONB for extensibility (content_type, source info, etc.)

  ## Backend Tracking

  - `backend_used` — Which backend processed this job
  - `backend_endpoint` — The endpoint URL used
  - `instance_id` — Vast.ai instance ID when applicable

  ## State Tracking

  - `state` — Current job state (queued, processing, completed, etc.)
  - `progress` — Progress percentage (0-100)
  - `pages_total` — Total pages in document
  - `pages_done` — Pages processed so far
  - `last_error` — Error message if failed
  - `result` — Conversion result (stored on completion)
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Lumainus.Conversion.ProcessingProfile

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          profile: ProcessingProfile.t(),
          filename: String.t(),
          byte_size: non_neg_integer(),
          tenant_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          submitted_at: DateTime.t() | nil,
          timeout_at: DateTime.t() | nil,
          code_version: atom(),
          metadata: map(),
          backend_used: atom() | nil,
          backend_endpoint: String.t() | nil,
          instance_id: integer() | nil,
          state: atom(),
          progress: non_neg_integer(),
          pages_total: non_neg_integer() | nil,
          pages_done: non_neg_integer(),
          last_error: String.t() | nil,
          result: map() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  @states [
    :queued,
    :provisioning,
    :starting,
    :processing,
    :completed,
    :failed,
    :cancelled,
    :timeout
  ]
  @backend_types [:local_cpu, :local_gpu, :docker_cpu, :docker_gpu, :cloud]

  schema "conversion_jobs" do
    field(:profile, Ecto.Enum, values: [:standard, :enhanced])
    field(:filename, :string)
    field(:byte_size, :integer)
    field(:tenant_id, :binary_id)
    field(:user_id, :binary_id)
    field(:submitted_at, :utc_datetime_usec)
    field(:timeout_at, :utc_datetime_usec)
    field(:code_version, Ecto.Enum, values: [:v2], default: :v2)
    field(:metadata, :map, default: %{})

    # Backend tracking (written after routing)
    field(:backend_used, Ecto.Enum, values: @backend_types)
    field(:backend_endpoint, :string)
    field(:instance_id, :integer)

    # State tracking
    field(:state, Ecto.Enum, values: @states, default: :queued)
    field(:progress, :integer, default: 0)
    field(:pages_total, :integer)
    field(:pages_done, :integer, default: 0)
    field(:last_error, :string)
    field(:result, :map)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Create a new job changeset from submission attributes.

  Automatically sets:
  - `submitted_at` to current UTC time
  - `timeout_at` based on profile default or custom timeout_ms
  - `code_version` to :v2
  - `state` to :queued

  ## Options

  - `:profile` (required) — :standard or :enhanced
  - `:filename` (required) — Original filename
  - `:byte_size` (required) — File size in bytes
  - `:tenant_id` — Organization ID
  - `:user_id` — Submitting user ID
  - `:timeout_ms` — Custom timeout (capped at max)
  - `:metadata` — Additional metadata map
  """
  @spec new(map()) :: Ecto.Changeset.t()
  def new(attrs) do
    timeout_ms = calculate_timeout(attrs)
    now = DateTime.utc_now()

    %__MODULE__{}
    |> cast(attrs, [:profile, :filename, :byte_size, :tenant_id, :user_id, :metadata])
    |> validate_required([:profile, :filename, :byte_size])
    |> put_change(:submitted_at, now)
    |> put_change(:timeout_at, DateTime.add(now, timeout_ms, :millisecond))
    |> put_change(:code_version, :v2)
    |> put_change(:state, :queued)
  end

  @doc """
  Standard changeset for updating an existing job.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :state,
      :progress,
      :pages_total,
      :pages_done,
      :last_error,
      :result,
      :backend_used,
      :backend_endpoint,
      :instance_id
    ])
  end

  @doc """
  Return list of valid states.
  """
  @spec states() :: [atom()]
  def states, do: @states

  @doc """
  Return list of valid backend types.
  """
  @spec backend_types() :: [atom()]
  def backend_types, do: @backend_types

  # Private helpers

  defp calculate_timeout(attrs) do
    profile = attrs[:profile] || :standard
    requested = attrs[:timeout_ms]
    default = ProcessingProfile.default_timeout_ms(profile)
    max = ProcessingProfile.max_timeout_ms()

    cond do
      is_nil(requested) -> default
      requested > max -> max
      true -> requested
    end
  end
end
