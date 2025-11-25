defmodule Lumainus.Repo.Migrations.AllowCloudDoclingBackend do
  @moduledoc """
  Updates the docling_backend constraints to include 'cloud' as a valid option.

  Affects:
  - users.docling_backend_valid constraint
  - ingestion_jobs.backend_valid constraint
  """
  use Ecto.Migration

  def up do
    # Update users table constraint
    drop(constraint(:users, :docling_backend_valid))

    create(
      constraint(:users, :docling_backend_valid,
        check: "docling_backend in ('local', 'fast', 'cloud')"
      )
    )

    # Update ingestion_jobs table constraint
    drop(constraint(:ingestion_jobs, :backend_valid))

    create(
      constraint(:ingestion_jobs, :backend_valid, check: "backend in ('local', 'fast', 'cloud')")
    )
  end

  def down do
    # Revert users constraint
    drop(constraint(:users, :docling_backend_valid))

    create(
      constraint(:users, :docling_backend_valid, check: "docling_backend in ('local','fast')")
    )

    # Revert ingestion_jobs constraint
    drop(constraint(:ingestion_jobs, :backend_valid))
    create(constraint(:ingestion_jobs, :backend_valid, check: "backend in ('local','fast')"))
  end
end
