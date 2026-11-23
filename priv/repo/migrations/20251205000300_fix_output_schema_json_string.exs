defmodule Medlum.Repo.Migrations.FixOutputSchemaJsonString do
  @moduledoc """
  Fix output_schema fields that were incorrectly stored as JSON strings.

  A previous migration bug stored the schema as a double-encoded JSON string
  instead of as a proper jsonb object. This migration detects and fixes those rows.
  """
  use Ecto.Migration

  def up do
    execute(&fix_schemas/0)
  end

  def down do
    # No-op: can't reverse this fix
    :ok
  end

  defp fix_schemas do
    repo = Medlum.Repo

    # Find rows where output_schema is a string (JSON-encoded) instead of a map
    {:ok, result} =
      repo.query(
        """
        SELECT id, output_schema
        FROM report_section_templates
        WHERE jsonb_typeof(output_schema) = 'string'
        """,
        []
      )

    for [id, schema_string] <- result.rows do
      # The schema is double-encoded - it's a JSON string containing JSON
      # We need to decode it and store it properly
      case Jason.decode(schema_string) do
        {:ok, decoded} when is_map(decoded) ->
          repo.query!(
            "UPDATE report_section_templates SET output_schema = $1 WHERE id = $2",
            [decoded, id]
          )

        _ ->
          # If it's not valid JSON, leave it alone
          :ok
      end
    end

    :ok
  end
end
