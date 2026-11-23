defmodule Medlum.Repo.Migrations.BackfillLlmDefaults do
  @moduledoc """
  Backfill default values for new LLM configuration fields.

  This migration:
  1. Sets the default system prompt on all report_templates that don't have one
  2. Sets sensible defaults on report_section_templates for fields that have column defaults

  The system prompt is extracted from the hard-coded value in section_runner.ex,
  making it configurable via the database going forward.
  """
  use Ecto.Migration

  @default_system_prompt """
  You are Medlum, a clinical documentation system.
  Produce structured markdown with inline citations like [doc-001].
  Return JSON that matches the provided schema exactly.
  """

  def up do
    # Backfill template-level system prompt
    execute("""
    UPDATE report_templates
    SET system_prompt = '#{escape_sql(@default_system_prompt)}'
    WHERE system_prompt IS NULL
    """)

    # Note: Section-level defaults are handled by column defaults in the schema.
    # We only backfill values where explicit NULL was stored (which shouldn't happen
    # for new columns, but ensures consistency for any edge cases).

    # Backfill response_mime_type for existing sections
    execute("""
    UPDATE report_section_templates
    SET response_mime_type = 'application/json'
    WHERE response_mime_type IS NULL
    """)

    # Backfill timeout_ms
    execute("""
    UPDATE report_section_templates
    SET timeout_ms = 120000
    WHERE timeout_ms IS NULL
    """)

    # Backfill max_retries
    execute("""
    UPDATE report_section_templates
    SET max_retries = 3
    WHERE max_retries IS NULL
    """)

    # Backfill retry_delay_ms
    execute("""
    UPDATE report_section_templates
    SET retry_delay_ms = 1000
    WHERE retry_delay_ms IS NULL
    """)

    # Backfill candidate_count
    execute("""
    UPDATE report_section_templates
    SET candidate_count = 1
    WHERE candidate_count IS NULL
    """)

    # Backfill stop_sequences as empty array
    execute("""
    UPDATE report_section_templates
    SET stop_sequences = '{}'
    WHERE stop_sequences IS NULL
    """)
  end

  def down do
    # Rollback is a no-op since we can't know what the previous values were
    # and setting to NULL would break things
    :ok
  end

  defp escape_sql(string) do
    string
    |> String.replace("'", "''")
    |> String.trim()
  end
end
