# Preview what will be cleaned up (dry run)
#
# Shows what the surgical cleanup will remove WITHOUT actually deleting
# Run with: mix run examples/preview_cleanup.exs

alias Lumainus.Repo
alias Lumainus.Reports.{ReportRun, ReportSectionRun, ReportSectionCitation}
alias Lumainus.AI.LlmInvocation
import Ecto.Query

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("  CLEANUP PREVIEW (DRY RUN)")
IO.puts(String.duplicate("=", 70) <> "\n")

# Find problematic section runs
problematic_runs =
  ReportSectionRun
  |> where([r], not is_nil(r.error))
  |> preload([:section_template, :llm_invocation])
  |> Repo.all()
  |> Enum.filter(fn run ->
    error_msg = inspect(run.error)

    String.contains?(error_msg, "ReqLLM") or
      String.contains?(error_msg, "NimbleOptions") or
      String.contains?(error_msg, "items") or
      String.contains?(error_msg, "invalid_schema")
  end)

IO.puts("📊 Database Statistics:\n")

total_section_runs = Repo.aggregate(ReportSectionRun, :count)
total_llm = Repo.aggregate(LlmInvocation, :count)
total_citations = Repo.aggregate(ReportSectionCitation, :count)

IO.puts("Current state:")
IO.puts("  • Section runs: #{total_section_runs} total")
IO.puts("  • LLM invocations: #{total_llm} total")
IO.puts("  • Citations: #{total_citations} total")

IO.puts("\n🔍 Found #{length(problematic_runs)} problematic runs:\n")

if length(problematic_runs) > 0 do
  problematic_runs
  |> Enum.with_index(1)
  |> Enum.each(fn {run, idx} ->
    section_title = run.section_template.title
    error_msg = run.error["message"] || inspect(run.error)
    error_preview = String.slice(error_msg, 0, 100)

    IO.puts("#{idx}. Section: #{section_title}")
    IO.puts("   ID: #{run.id}")
    IO.puts("   Status: #{run.status}")
    IO.puts("   Error: #{error_preview}...")

    IO.puts(
      "   LLM Invocation: #{if run.llm_invocation_id, do: "Yes (#{run.llm_invocation_id})", else: "None"}"
    )

    IO.puts("")
  end)

  # Count related data
  llm_invocation_ids =
    problematic_runs |> Enum.map(& &1.llm_invocation_id) |> Enum.reject(&is_nil/1)

  section_run_ids = Enum.map(problematic_runs, & &1.id)

  related_llm_count =
    if length(llm_invocation_ids) > 0 do
      Repo.aggregate(from(l in LlmInvocation, where: l.id in ^llm_invocation_ids), :count)
    else
      0
    end

  related_citations_count =
    if length(section_run_ids) > 0 do
      Repo.aggregate(
        from(c in ReportSectionCitation, where: c.section_run_id in ^section_run_ids),
        :count
      )
    else
      0
    end

  IO.puts(String.duplicate("-", 70))
  IO.puts("\n📉 After cleanup:\n")
  IO.puts("Will DELETE:")

  IO.puts(
    "  • #{length(problematic_runs)} section runs (#{Float.round(length(problematic_runs) / total_section_runs * 100, 1)}%)"
  )

  IO.puts(
    "  • #{related_llm_count} LLM invocations (#{if total_llm > 0, do: Float.round(related_llm_count / total_llm * 100, 1), else: 0}%)"
  )

  IO.puts(
    "  • #{related_citations_count} citations (#{if total_citations > 0, do: Float.round(related_citations_count / total_citations * 100, 1), else: 0}%)"
  )

  IO.puts("\nWill KEEP:")

  IO.puts(
    "  • #{total_section_runs - length(problematic_runs)} section runs (#{Float.round((total_section_runs - length(problematic_runs)) / total_section_runs * 100, 1)}%)"
  )

  IO.puts("  • #{total_llm - related_llm_count} LLM invocations")
  IO.puts("  • #{total_citations - related_citations_count} citations")

  IO.puts("\n" <> String.duplicate("=", 70))
  IO.puts("\n✅ Ready to clean!")
  IO.puts("")
  IO.puts("To execute the cleanup, run:")
  IO.puts("  $ mix run examples/surgical_db_cleanup.exs")
  IO.puts("")
else
  IO.puts("✓ No problematic runs found!")
  IO.puts("")
  IO.puts("Your database is clean. If you're still seeing errors,")
  IO.puts("they are likely NEW errors from recent runs.")
  IO.puts("")
  IO.puts("Try running a section again to see if the fix worked:")
  IO.puts("  1. Go to http://localhost:4000/reports")
  IO.puts("  2. Click 'Run Section' or 'Run All Sections'")
  IO.puts("")
end

IO.puts(String.duplicate("=", 70) <> "\n")
