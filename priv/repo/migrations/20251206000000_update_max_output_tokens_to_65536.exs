defmodule Medlum.Repo.Migrations.UpdateMaxOutputTokensTo65536 do
  use Ecto.Migration

  @doc """
  Updates all report_section_templates to use 65536 max_output_tokens.

  This matches the actual Gemini 2.5 model limits (Pro, Flash, Flash-Lite all support 65536).
  Previous default of 2048 was unnecessarily restrictive.
  """
  def up do
    execute("""
    UPDATE report_section_templates
    SET max_output_tokens = 65536
    WHERE max_output_tokens IS NULL OR max_output_tokens < 65536
    """)
  end

  def down do
    execute("""
    UPDATE report_section_templates
    SET max_output_tokens = 2048
    WHERE max_output_tokens = 65536
    """)
  end
end
