defmodule Medlum.Repo.Migrations.AddDoclingBackendFields do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add(:docling_backend, :string, default: "local", null: false)
    end

    alter table(:ingestion_jobs) do
      add(:backend, :string, default: "local", null: false)
    end

    execute("UPDATE users SET docling_backend = 'local' WHERE docling_backend IS NULL")
    execute("UPDATE ingestion_jobs SET backend = 'local' WHERE backend IS NULL")

    create(
      constraint(:users, :docling_backend_valid, check: "docling_backend in ('local','fast')")
    )

    create(constraint(:ingestion_jobs, :backend_valid, check: "backend in ('local','fast')"))
  end

  def down do
    drop(constraint(:ingestion_jobs, :backend_valid))
    drop(constraint(:users, :docling_backend_valid))

    alter table(:ingestion_jobs) do
      remove(:backend)
    end

    alter table(:users) do
      remove(:docling_backend)
    end
  end
end
