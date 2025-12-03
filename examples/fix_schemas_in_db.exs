# Fix schemas in database - ADD missing "items" to array fields
#
# Gemini's structured output requires array types to have an "items" field
# that defines what type of objects are in the array.
#
# Run with: mix run examples/fix_schemas_in_db.exs

alias Lumainus.Repo
alias Lumainus.Reports.ReportSectionTemplate
import Ecto.Query

IO.puts("\n=== Fixing Schemas in Database (Adding missing 'items' to arrays) ===\n")

# The correct items schema for citations
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

# Find all section templates
sections = Repo.all(ReportSectionTemplate)

IO.puts("Found #{length(sections)} section templates")
IO.puts("")

for section <- sections do
  schema = section.output_schema

  IO.puts("Section: #{section.title} (#{section.identifier})")

  arrays_missing_items = find_arrays_missing_items(schema)

  if length(arrays_missing_items) > 0 do
    IO.puts(
      "  ⚠️  Found #{length(arrays_missing_items)} array field(s) missing 'items': #{inspect(arrays_missing_items)}"
    )

    IO.inspect(schema, label: "  Current schema", pretty: true, limit: :infinity)

    # Fix the schema by adding items to array fields
    fixed_schema = add_items_to_arrays(schema)
    IO.inspect(fixed_schema, label: "  Fixed schema", pretty: true, limit: :infinity)

    # Update the database
    case Ecto.Changeset.change(section, %{output_schema: fixed_schema}) |> Repo.update() do
      {:ok, _} ->
        IO.puts("  ✓ Schema updated successfully!")

      {:error, changeset} ->
        IO.puts("  ✗ Failed to update: #{inspect(changeset.errors)}")
    end
  else
    IO.puts("  ✓ Schema already has 'items' on all array fields")
  end

  IO.puts("")
end

IO.puts("=== Done ===\n")

# Helper functions

defp find_arrays_missing_items(schema) when is_map(schema) do
  properties = Map.get(schema, "properties", %{})

  properties
  |> Enum.filter(fn {_key, value} ->
    is_map(value) &&
      Map.get(value, "type") == "array" &&
      !Map.has_key?(value, "items")
  end)
  |> Enum.map(fn {key, _} -> key end)
end

defp find_arrays_missing_items(_), do: []

defp add_items_to_arrays(schema) when is_map(schema) do
  properties = Map.get(schema, "properties", %{})

  fixed_properties =
    Enum.reduce(properties, %{}, fn {key, value}, acc ->
      fixed_value =
        if is_map(value) && Map.get(value, "type") == "array" && !Map.has_key?(value, "items") do
          # Add appropriate items schema based on field name
          items_schema = items_schema_for_field(key)

          value
          |> Map.put("items", items_schema)
        else
          value
        end

      Map.put(acc, key, fixed_value)
    end)

  Map.put(schema, "properties", fixed_properties)
end

defp add_items_to_arrays(schema), do: schema

defp items_schema_for_field("citations") do
  # Use the standard citations schema
  %{
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
end

defp items_schema_for_field(_) do
  # Default to string items for unknown array fields
  %{"type" => "string"}
end
