defmodule Medlum.Repo.Migrations.AddSectionTemplateInsertedIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS report_section_runs_section_template_inserted_idx
    ON report_section_runs (section_template_id, inserted_at DESC)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS report_section_runs_section_template_inserted_idx")
  end
end
