# Diagnostic script for schema errors
#
# This shows what schemas are currently in the database
# Run with: mix run examples/diagnose_schema_error.exs

alias Lumainus.Repo
alias Lumainus.Reports.ReportSectionTemplate
alias Lumainus.Reports.ReportTemplate
import Ecto.Query

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("  SCHEMA DIAGNOSTICS")
IO.puts(String.duplicate("=", 70) <> "\n")

# Check if ReqLLM is being loaded
IO.puts("Module status:")
IO.puts("  Gemini: #{if Code.ensure_loaded?(Gemini), do: "✓ loaded", else: "✗ not loaded"}")

IO.puts(
  "  ReqLLM: #{if Code.ensure_loaded?(ReqLLM), do: "✓ loaded (THIS IS THE PROBLEM!)", else: "✗ not loaded"}"
)

IO.puts("  Altar: #{if Code.ensure_loaded?(Altar), do: "✓ loaded", else: "✗ not loaded"}")
IO.puts("")

# Check templates
templates = Repo.all(ReportTemplate)
IO.puts("Report Templates: #{length(templates)}")

for template <- templates do
  IO.puts("\nTemplate: #{template.name} (#{template.slug})")

  sections =
    ReportSectionTemplate
    |> where([s], s.template_id == ^template.id)
    |> order_by([s], asc: s.position)
    |> Repo.all()

  IO.puts("  Sections: #{length(sections)}")

  for section <- sections do
    schema = section.output_schema

    has_problematic_items =
      is_map(schema) &&
        Enum.any?(Map.get(schema, "properties", %{}), fn {_key, value} ->
          is_map(value) && Map.has_key?(value, "items")
        end)

    status_icon = if has_problematic_items, do: "⚠️ ", else: "✓"

    IO.puts("    #{status_icon} #{section.title} (#{section.identifier})")

    if has_problematic_items do
      IO.puts("        🔥 HAS 'items' FIELD - This causes ReqLLM validation error!")

      # Show which field has items
      Enum.each(Map.get(schema, "properties", %{}), fn {key, value} ->
        if is_map(value) && Map.has_key?(value, "items") do
          IO.puts("        Field '#{key}' has 'items': #{inspect(value["items"], limit: 3)}")
        end
      end)
    end
  end
end

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("  PROBLEM SUMMARY")
IO.puts(String.duplicate("=", 70))

problem_count =
  ReportSectionTemplate
  |> Repo.all()
  |> Enum.count(fn section ->
    schema = section.output_schema

    is_map(schema) &&
      Enum.any?(Map.get(schema, "properties", %{}), fn {_key, value} ->
        is_map(value) && Map.has_key?(value, "items")
      end)
  end)

IO.puts("")

if problem_count > 0 do
  IO.puts("⚠️  FOUND #{problem_count} section(s) with problematic schemas!")
  IO.puts("")
  IO.puts("The 'items' field in schema causes ReqLLM.Error.Validation.Error")
  IO.puts("because NimbleOptions doesn't support :items option.")
  IO.puts("")
  IO.puts("SOLUTIONS:")
  IO.puts("")
  IO.puts("Option 1: Reset database (easiest, loses data)")
  IO.puts("  $ mix ecto.reset")
  IO.puts("")
  IO.puts("Option 2: Run the fix script (keeps data)")
  IO.puts("  $ mix run examples/fix_schemas_in_db.exs")
  IO.puts("")
  IO.puts("Option 3: Create migration (for production)")
  IO.puts("  $ mix ecto.gen.migration fix_report_section_schemas")
  IO.puts("  Then edit the migration file to update schemas")
  IO.puts("")
else
  IO.puts("✓ All schemas look good! No 'items' fields found.")
  IO.puts("")
  IO.puts("If you're still seeing errors, they might be coming from:")
  IO.puts("  1. Cached old section runs in report_section_runs table")
  IO.puts("  2. A different code path")
  IO.puts("")
  IO.puts("Try running a new section generation to see if it works now.")
  IO.puts("")
end

IO.puts(String.duplicate("=", 70) <> "\n")
