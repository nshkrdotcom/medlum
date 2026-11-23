defmodule Medlum.Repo.Migrations.RenameObanWorkers do
  use Ecto.Migration

  def up do
    # Oban stores worker module names without the Elixir prefix. Match the
    # prior namespace and the exact paths of the four workers we own.
    execute("""
    UPDATE oban_jobs AS job
    SET worker = 'Medlum.' || owned.module_path
    FROM (VALUES
      ('Documents.DoclingIngestionWorker'),
      ('Documents.IngestionCleanupWorker'),
      ('Reports.SectionRunWorker'),
      ('Reports.StaleRunWorker')
    ) AS owned(module_path)
    WHERE job.worker = concat('Lum', 'ainus', '.', owned.module_path)
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message: "Restore the previous worker names from the pre-upgrade database backup"
  end
end
