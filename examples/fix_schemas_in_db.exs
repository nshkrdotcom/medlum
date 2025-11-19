# Fix schemas in database
#
# The schema validation error occurs because old schemas with "items" are
# stored in the database. This script updates them to the new format.
#
# Run with: mix run examples/fix_schemas_in_db.exs

alias Lumainus.Repo
alias Lumainus.Reports.ReportSectionTemplate
import Ecto.Query

IO.puts("\n=== Fixing Schemas in Database ===\n")

# Find all section templates
sections = Repo.all(ReportSectionTemplate)

IO.puts("Found #{length(sections)} section templates")
IO.puts("")

for section <- sections do
  schema = section.output_schema

  IO.puts("Section: #{section.title} (#{section.identifier})")
  IO.puts("  Current schema has 'items'?: #{has_items?(schema)}")

  if has_items?(schema) do
    IO.puts("  ⚠️  OLD SCHEMA DETECTED - needs fixing!")
    IO.inspect(schema, label: "  Old schema", pretty: true, limit: :infinity)

    # Fix the schema
    fixed_schema = fix_schema(schema)
    IO.inspect(fixed_schema, label: "  New schema", pretty: true, limit: :infinity)

    # Update the database
    case Ecto.Changeset.change(section, %{output_schema: fixed_schema}) |> Repo.update() do
      {:ok, _} ->
        IO.puts("  ✓ Schema updated successfully!")

      {:error, changeset} ->
        IO.puts("  ✗ Failed to update: #{inspect(changeset.errors)}")
    end
  else
    IO.puts("  ✓ Schema is already in correct format")
  end

  IO.puts("")
end

IO.puts("=== Done ===\n")

# Helper functions
defp has_items?(schema) when is_map(schema) do
  # Check if any field has "items" key
  Enum.any?(Map.get(schema, "properties", %{}), fn {_key, value} ->
    is_map(value) && Map.has_key?(value, "items")
  end)
end

defp has_items?(_), do: false

defp fix_schema(schema) when is_map(schema) do
  # Remove "items" from all array fields and replace with description
  properties = Map.get(schema, "properties", %{})

  fixed_properties =
    Enum.reduce(properties, %{}, fn {key, value}, acc ->
      fixed_value =
        if is_map(value) && Map.get(value, "type") == "array" && Map.has_key?(value, "items") do
          # Remove items, keep type and add description
          items_info = inspect_items(Map.get(value, "items"))

          %{
            "type" => "array",
            "description" => "Array of #{items_info}"
          }
        else
          value
        end

      Map.put(acc, key, fixed_value)
    end)

  schema
  |> Map.put("properties", fixed_properties)
end

defp fix_schema(schema), do: schema

defp inspect_items(%{"type" => "object", "properties" => props}) when is_map(props) do
  fields = Map.keys(props) |> Enum.join(", ")
  "objects with fields: #{fields}"
end

defp inspect_items(%{"type" => type}), do: type
defp inspect_items(_), do: "items"
