defmodule Lumainus.GPU.Session do
  @moduledoc """
  Schema for GPU instance sessions.

  A session represents a single provisioning-to-destruction lifecycle
  of a GPU instance. Tracks:
  - Instance details (GPU, CPU, RAM, location)
  - Network configuration (IP, SSH, endpoint)
  - Cost accumulation
  - Activity and idle time
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending provisioning booting configuring_dns configuring_ssl ready running stopping stopped destroying destroyed failed)
  @destroy_reasons ~w(manual auto_shutdown idle_timeout cron error user_request cost_limit api_error)

  schema "gpu_instance_sessions" do
    # Vast.ai identifiers
    field(:instance_id, :integer)
    field(:offer_id, :integer)
    field(:machine_id, :integer)

    # Instance details
    field(:gpu_name, :string)
    field(:gpu_ram_mb, :integer)
    field(:cpu_name, :string)
    field(:cpu_cores, :integer)
    field(:ram_mb, :integer)
    field(:disk_gb, :integer)
    field(:geolocation, :string)

    # Network
    field(:public_ip, :string)
    field(:ssh_host, :string)
    field(:ssh_port, :integer)
    field(:endpoint, :string)
    field(:https_enabled, :boolean, default: false)

    # Cost
    field(:hourly_cost, :decimal)
    field(:total_cost, :decimal, default: Decimal.new(0))

    # Lifecycle
    field(:status, :string, default: "pending")
    field(:provisioned_at, :utc_datetime_usec)
    field(:ready_at, :utc_datetime_usec)
    field(:destroyed_at, :utc_datetime_usec)
    field(:destroy_reason, :string)

    # Activity tracking
    field(:last_activity_at, :utc_datetime_usec)
    field(:idle_minutes, :integer, default: 0)

    # Metadata
    field(:label, :string)
    field(:image, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :instance_id,
      :offer_id,
      :machine_id,
      :gpu_name,
      :gpu_ram_mb,
      :cpu_name,
      :cpu_cores,
      :ram_mb,
      :disk_gb,
      :geolocation,
      :public_ip,
      :ssh_host,
      :ssh_port,
      :endpoint,
      :https_enabled,
      :hourly_cost,
      :total_cost,
      :status,
      :provisioned_at,
      :ready_at,
      :destroyed_at,
      :destroy_reason,
      :last_activity_at,
      :idle_minutes,
      :label,
      :image,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:destroy_reason, @destroy_reasons ++ [nil])
  end

  def status_changeset(session, status, opts \\ []) do
    attrs = %{status: status}

    attrs =
      case status do
        "provisioning" ->
          Map.put(attrs, :provisioned_at, DateTime.utc_now())

        "ready" ->
          Map.put(attrs, :ready_at, DateTime.utc_now())

        "running" ->
          Map.put(attrs, :ready_at, attrs[:ready_at] || DateTime.utc_now())

        "destroyed" ->
          attrs
          |> Map.put(:destroyed_at, DateTime.utc_now())
          |> Map.put(:destroy_reason, Keyword.get(opts, :reason, "manual"))

        "failed" ->
          attrs
          |> Map.put(:destroyed_at, DateTime.utc_now())
          |> Map.put(:destroy_reason, Keyword.get(opts, :reason, "error"))

        _ ->
          attrs
      end

    changeset(session, attrs)
  end

  def activity_changeset(session) do
    changeset(session, %{
      last_activity_at: DateTime.utc_now(),
      idle_minutes: 0
    })
  end

  def idle_changeset(session, idle_minutes) do
    changeset(session, %{idle_minutes: idle_minutes})
  end

  @doc "Calculate total cost based on runtime"
  def calculate_cost(%__MODULE__{} = session) do
    case {session.provisioned_at, session.hourly_cost} do
      {nil, _} ->
        Decimal.new(0)

      {_, nil} ->
        Decimal.new(0)

      {start, hourly} ->
        end_time = session.destroyed_at || DateTime.utc_now()
        hours = DateTime.diff(end_time, start, :second) / 3600
        Decimal.mult(hourly, Decimal.from_float(hours))
    end
  end

  def statuses, do: @statuses
  def destroy_reasons, do: @destroy_reasons
end
