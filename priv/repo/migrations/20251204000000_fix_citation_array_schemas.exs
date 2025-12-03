defmodule Lumainus.Repo.Migrations.FixCitationArraySchemas do
  @moduledoc """
  Fix report section template schemas that have array fields without the required `items` property.

  Gemini's structured output API requires all array types to have an `items` field that defines
  what type of objects are in the array. Old templates were created without this field.

  This migration:
  1. Finds all section templates with JSON Schema format (has "properties" key)
  2. For each array field missing "items", adds the appropriate items schema
  3. Specifically handles the "citations" array with its known structure
  """
  use Ecto.Migration

  @citations_items_schema %{
    "type" => "object",
    "properties" => %{
      "label" => %{"type" => "string"},
      "document_id" => %{"type" => "string"},
      "document_reference" => %{"type" => "string"},
      "line_start" => %{"type" => "integer"},
      "line_end" => %{"type" => "integer"},
      "excerpt" => %{"type" => "string"}
    }
  }

  def up do
    # We need to do this in Elixir since we need to handle JSON manipulation
    # that's complex to do in raw SQL
    execute(&fix_schemas/0)
  end

  def down do
    # No-op: removing items would break things, and we can't know what the original was
    :ok
  end

  defp fix_schemas do
    import Ecto.Query

    repo = Lumainus.Repo
    alias Lumainus.Reports.ReportSectionTemplate

    templates = repo.all(from(t in ReportSectionTemplate, select: t))

    for template <- templates do
      schema = template.output_schema

      if needs_fix?(schema) do
        fixed_schema = fix_schema(schema)

        template
        |> Ecto.Changeset.change(%{output_schema: fixed_schema})
        |> repo.update!()
      end
    end

    :ok
  end

  defp needs_fix?(schema) when is_map(schema) do
    # Only fix JSON Schema format (has "properties" key)
    # Skip "fields" format which is handled differently
    properties = Map.get(schema, "properties", %{})

    is_map(properties) and
      Enum.any?(properties, fn {_key, value} ->
        is_map(value) and
          Map.get(value, "type") == "array" and
          not Map.has_key?(value, "items")
      end)
  end

  defp needs_fix?(_), do: false

  defp fix_schema(schema) when is_map(schema) do
    properties = Map.get(schema, "properties", %{})

    fixed_properties =
      Enum.reduce(properties, %{}, fn {key, value}, acc ->
        fixed_value =
          if is_map(value) and Map.get(value, "type") == "array" and
               not Map.has_key?(value, "items") do
            Map.put(value, "items", items_schema_for_field(key))
          else
            value
          end

        Map.put(acc, key, fixed_value)
      end)

    Map.put(schema, "properties", fixed_properties)
  end

  defp items_schema_for_field("citations"), do: @citations_items_schema

  defp items_schema_for_field(_) do
    # Default to string items for unknown array fields
    %{"type" => "string"}
  end
end
