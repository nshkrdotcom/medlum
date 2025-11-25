defmodule Lumainus.Repo.Migrations.CreateGpuInstanceEvents do
  @moduledoc """
  Creates comprehensive event logging for GPU instance lifecycle.

  Tracks all events related to:
  - Instance provisioning (search, create, boot, DNS, SSL)
  - Instance lifecycle (running, stopped, destroyed)
  - Auto-shutdown events (idle checks, scheduled shutdowns)
  - Health checks and connectivity
  - Cron/scheduled task executions
  - Errors and failures
  """

  use Ecto.Migration

  def change do
    # Main events table
    create table(:gpu_instance_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      # Instance identification (nullable for system-level events)
      add(:instance_id, :integer)
      add(:offer_id, :integer)
      add(:machine_id, :integer)

      # Event classification
      add(:event_type, :string, null: false)
      add(:event_category, :string, null: false)
      add(:severity, :string, null: false, default: "info")

      # Event details
      add(:message, :text, null: false)
      add(:details, :map, default: %{})

      # Instance state at time of event
      add(:instance_status, :string)
      add(:public_ip, :string)
      add(:endpoint, :string)
      add(:ssh_host, :string)
      add(:ssh_port, :integer)

      # Cost tracking
      add(:hourly_cost, :decimal, precision: 10, scale: 6)
      add(:cumulative_cost, :decimal, precision: 10, scale: 4)

      # Source of event
      add(:source, :string, null: false, default: "system")
      add(:source_pid, :string)
      add(:triggered_by, :string)

      # Error tracking
      add(:error_type, :string)
      add(:error_message, :text)
      add(:stacktrace, :text)

      # Duration tracking (for operations that take time)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      add(:duration_ms, :integer)

      # Correlation
      add(:correlation_id, :binary_id)

      add(
        :parent_event_id,
        references(:gpu_instance_events, type: :binary_id, on_delete: :nilify_all)
      )

      timestamps(type: :utc_datetime_usec)
    end

    # Indexes for common queries
    create(index(:gpu_instance_events, [:instance_id]))
    create(index(:gpu_instance_events, [:event_type]))
    create(index(:gpu_instance_events, [:event_category]))
    create(index(:gpu_instance_events, [:severity]))
    create(index(:gpu_instance_events, [:inserted_at]))
    create(index(:gpu_instance_events, [:correlation_id]))
    create(index(:gpu_instance_events, [:source]))

    # Composite indexes for common query patterns
    create(index(:gpu_instance_events, [:instance_id, :inserted_at]))
    create(index(:gpu_instance_events, [:event_category, :event_type, :inserted_at]))
    create(index(:gpu_instance_events, [:severity, :inserted_at]))

    # Check constraints for valid values
    create(
      constraint(:gpu_instance_events, :valid_severity,
        check: "severity IN ('debug', 'info', 'warning', 'error', 'critical')"
      )
    )

    create(
      constraint(:gpu_instance_events, :valid_event_category,
        check:
          "event_category IN ('provisioning', 'lifecycle', 'health', 'auto_shutdown', 'activity', 'dns', 'ssl', 'cron', 'config', 'error', 'system')"
      )
    )

    # Instance sessions table - tracks each provisioning session
    create table(:gpu_instance_sessions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      # Vast.ai identifiers
      add(:instance_id, :integer)
      add(:offer_id, :integer)
      add(:machine_id, :integer)

      # Instance details
      add(:gpu_name, :string)
      add(:gpu_ram_mb, :integer)
      add(:cpu_name, :string)
      add(:cpu_cores, :integer)
      add(:ram_mb, :integer)
      add(:disk_gb, :integer)
      add(:geolocation, :string)

      # Network
      add(:public_ip, :string)
      add(:ssh_host, :string)
      add(:ssh_port, :integer)
      add(:endpoint, :string)
      add(:https_enabled, :boolean, default: false)

      # Cost
      add(:hourly_cost, :decimal, precision: 10, scale: 6)
      add(:total_cost, :decimal, precision: 10, scale: 4, default: 0)

      # Lifecycle
      add(:status, :string, null: false, default: "pending")
      add(:provisioned_at, :utc_datetime_usec)
      add(:ready_at, :utc_datetime_usec)
      add(:destroyed_at, :utc_datetime_usec)
      add(:destroy_reason, :string)

      # Activity tracking
      add(:last_activity_at, :utc_datetime_usec)
      add(:idle_minutes, :integer, default: 0)

      # Metadata
      add(:label, :string)
      add(:image, :string)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:gpu_instance_sessions, [:instance_id], where: "destroyed_at IS NULL"))
    create(index(:gpu_instance_sessions, [:status]))
    create(index(:gpu_instance_sessions, [:provisioned_at]))
    create(index(:gpu_instance_sessions, [:destroyed_at]))

    create(
      constraint(:gpu_instance_sessions, :valid_status,
        check:
          "status IN ('pending', 'provisioning', 'booting', 'configuring_dns', 'configuring_ssl', 'ready', 'running', 'stopping', 'stopped', 'destroying', 'destroyed', 'failed')"
      )
    )

    # Daily/hourly aggregates for cost tracking and analytics
    create table(:gpu_usage_aggregates, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      # "hourly", "daily", "monthly"
      add(:period_type, :string, null: false)
      add(:period_start, :utc_datetime, null: false)
      add(:period_end, :utc_datetime, null: false)

      # Usage metrics
      add(:total_runtime_minutes, :integer, default: 0)
      add(:total_cost, :decimal, precision: 10, scale: 4, default: 0)
      add(:instance_count, :integer, default: 0)
      add(:job_count, :integer, default: 0)
      add(:document_count, :integer, default: 0)

      # Event counts
      add(:provision_count, :integer, default: 0)
      add(:destroy_count, :integer, default: 0)
      add(:error_count, :integer, default: 0)
      add(:auto_shutdown_count, :integer, default: 0)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:gpu_usage_aggregates, [:period_type, :period_start]))
    create(index(:gpu_usage_aggregates, [:period_start]))
  end
end
