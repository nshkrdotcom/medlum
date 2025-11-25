defmodule Lumainus.GPU.Event do
  @moduledoc """
  Schema for GPU instance events.

  Tracks all lifecycle events for GPU instances including:
  - Provisioning steps (search, create, boot, DNS, SSL)
  - Runtime events (health checks, activity)
  - Shutdown events (manual, auto, cron)
  - Errors and failures
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @severities ~w(debug info warning error critical)
  @categories ~w(provisioning lifecycle health auto_shutdown activity dns ssl cron config error system)
  @sources ~w(system user cron auto_shutdown health_check provisioning instance_manager activity_tracker)

  schema "gpu_instance_events" do
    # Instance identification
    field(:instance_id, :integer)
    field(:offer_id, :integer)
    field(:machine_id, :integer)

    # Event classification
    field(:event_type, :string)
    field(:event_category, :string)
    field(:severity, :string, default: "info")

    # Event details
    field(:message, :string)
    field(:details, :map, default: %{})

    # Instance state
    field(:instance_status, :string)
    field(:public_ip, :string)
    field(:endpoint, :string)
    field(:ssh_host, :string)
    field(:ssh_port, :integer)

    # Cost tracking
    field(:hourly_cost, :decimal)
    field(:cumulative_cost, :decimal)

    # Source
    field(:source, :string, default: "system")
    field(:source_pid, :string)
    field(:triggered_by, :string)

    # Error tracking
    field(:error_type, :string)
    field(:error_message, :string)
    field(:stacktrace, :string)

    # Duration tracking
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:duration_ms, :integer)

    # Correlation
    field(:correlation_id, :binary_id)
    belongs_to(:parent_event, __MODULE__)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :instance_id,
      :offer_id,
      :machine_id,
      :event_type,
      :event_category,
      :severity,
      :message,
      :details,
      :instance_status,
      :public_ip,
      :endpoint,
      :ssh_host,
      :ssh_port,
      :hourly_cost,
      :cumulative_cost,
      :source,
      :source_pid,
      :triggered_by,
      :error_type,
      :error_message,
      :stacktrace,
      :started_at,
      :completed_at,
      :duration_ms,
      :correlation_id,
      :parent_event_id
    ])
    |> validate_required([:event_type, :event_category, :message])
    |> validate_inclusion(:severity, @severities)
    |> validate_inclusion(:event_category, @categories)
    |> validate_inclusion(:source, @sources)
  end

  # Helper to create event attrs with common fields
  def build(category, type, message, opts \\ []) do
    %{
      event_category: to_string(category),
      event_type: to_string(type),
      message: message,
      severity: Keyword.get(opts, :severity, "info"),
      source: Keyword.get(opts, :source, "system"),
      instance_id: Keyword.get(opts, :instance_id),
      offer_id: Keyword.get(opts, :offer_id),
      machine_id: Keyword.get(opts, :machine_id),
      details: Keyword.get(opts, :details, %{}),
      correlation_id: Keyword.get(opts, :correlation_id),
      public_ip: Keyword.get(opts, :public_ip),
      endpoint: Keyword.get(opts, :endpoint),
      instance_status: Keyword.get(opts, :instance_status),
      hourly_cost: Keyword.get(opts, :hourly_cost),
      error_type: Keyword.get(opts, :error_type),
      error_message: Keyword.get(opts, :error_message),
      stacktrace: Keyword.get(opts, :stacktrace),
      started_at: Keyword.get(opts, :started_at),
      completed_at: Keyword.get(opts, :completed_at),
      duration_ms: Keyword.get(opts, :duration_ms)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  def severities, do: @severities
  def categories, do: @categories
  def sources, do: @sources
end
