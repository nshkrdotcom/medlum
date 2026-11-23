defmodule Medlum.Repo.Migrations.RenameObanWorkers do
  use Ecto.Migration

  def up do
    # Oban stores worker module names without the Elixir prefix. Limit the
    # rewrite to the four worker paths owned by this application.
    execute("""
    UPDATE oban_jobs AS job
    SET worker = 'Medlum.' || owned.module_path
    FROM (VALUES
      ('Documents.DoclingIngestionWorker'),
      ('Documents.IngestionCleanupWorker'),
      ('Reports.SectionRunWorker'),
      ('Reports.StaleRunWorker')
    ) AS owned(module_path)
    WHERE substring(job.worker FROM '^[^.]+[.](.+)$') = owned.module_path
      AND job.worker <> 'Medlum.' || owned.module_path
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message: "Restore the previous worker names from the pre-upgrade database backup"
  end
end
