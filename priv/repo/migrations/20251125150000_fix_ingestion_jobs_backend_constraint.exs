defmodule Lumainus.Repo.Migrations.FixIngestionJobsBackendConstraint do
  @moduledoc """
  Fixes the ingestion_jobs.backend_valid constraint to include 'cloud' as a valid option.
  """
  use Ecto.Migration

  def up do
    # Drop old constraint and create new one with 'cloud' included
    drop(constraint(:ingestion_jobs, :backend_valid))

    create(
      constraint(:ingestion_jobs, :backend_valid, check: "backend in ('local', 'fast', 'cloud')")
    )
  end

  def down do
    drop(constraint(:ingestion_jobs, :backend_valid))
    create(constraint(:ingestion_jobs, :backend_valid, check: "backend in ('local', 'fast')"))
  end
end
