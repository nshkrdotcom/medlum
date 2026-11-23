defmodule Medlum.Repo.Migrations.CreateConversionJobs do
  use Ecto.Migration

  def change do
    create table(:conversion_jobs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      # Job definition
      add(:profile, :string, null: false)
      add(:filename, :string, null: false)
      add(:byte_size, :integer, null: false)
      add(:tenant_id, :binary_id)
      add(:user_id, :binary_id)
      add(:submitted_at, :utc_datetime_usec, null: false)
      add(:timeout_at, :utc_datetime_usec, null: false)
      add(:code_version, :string, null: false, default: "v2")
      add(:metadata, :map, default: %{})

      # Backend provenance (written after routing)
      add(:backend_used, :string)
      add(:backend_endpoint, :string)
      add(:instance_id, :integer)

      # State tracking
      add(:state, :string, null: false, default: "queued")
      add(:progress, :integer, default: 0)
      add(:pages_total, :integer)
      add(:pages_done, :integer, default: 0)
      add(:last_error, :text)
      add(:result, :map)

      timestamps(type: :utc_datetime_usec)
    end

    # Indexes for common queries
    create(index(:conversion_jobs, [:tenant_id]))
    create(index(:conversion_jobs, [:user_id]))
    create(index(:conversion_jobs, [:state]))
    create(index(:conversion_jobs, [:submitted_at]))
    create(index(:conversion_jobs, [:state, :submitted_at]))
  end
end
