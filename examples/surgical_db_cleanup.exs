# Surgical database cleanup for ReqLLM schema errors
#
# This carefully removes only the problematic cached data:
# - Report section runs with ReqLLM/schema validation errors
# - Associated LLM invocations with errors
# - Orphaned citations
#
# Run with: mix run examples/surgical_db_cleanup.exs

alias Lumainus.Repo
alias Lumainus.Reports.{ReportRun, ReportSectionRun, ReportSectionCitation}
alias Lumainus.AI.LlmInvocation
import Ecto.Query

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("  SURGICAL DATABASE CLEANUP")
IO.puts(String.duplicate("=", 70) <> "\n")

# Step 1: Find problematic section runs
IO.puts("🔍 Step 1: Finding problematic section runs...\n")

problematic_runs =
  ReportSectionRun
  |> where([r], not is_nil(r.error))
  |> preload(:llm_invocation)
  |> Repo.all()
  |> Enum.filter(fn run ->
    error_msg = inspect(run.error)

    String.contains?(error_msg, "ReqLLM") or
      String.contains?(error_msg, "NimbleOptions") or
      String.contains?(error_msg, "items") or
      String.contains?(error_msg, "invalid_schema")
  end)

IO.puts("Found #{length(problematic_runs)} section runs with schema validation errors")

if length(problematic_runs) > 0 do
  IO.puts("\nSample errors:")

  problematic_runs
  |> Enum.take(3)
  |> Enum.each(fn run ->
    error_msg = run.error["message"] || inspect(run.error)
    truncated = String.slice(error_msg, 0, 150)
    IO.puts("  • #{truncated}...")
  end)

  if length(problematic_runs) > 3 do
    IO.puts("  ... and #{length(problematic_runs) - 3} more")
  end
end

# Step 2: Find associated LLM invocations with errors
IO.puts("\n🔍 Step 2: Finding associated LLM invocations...\n")

llm_invocation_ids =
  problematic_runs
  |> Enum.map(& &1.llm_invocation_id)
  |> Enum.reject(&is_nil/1)

error_llm_invocations =
  if length(llm_invocation_ids) > 0 do
    LlmInvocation
    |> where([l], l.id in ^llm_invocation_ids)
    |> Repo.all()
  else
    []
  end

IO.puts("Found #{length(error_llm_invocations)} associated LLM invocations")

# Step 3: Find citations to be orphaned
IO.puts("\n🔍 Step 3: Finding citations that will be orphaned...\n")

section_run_ids = Enum.map(problematic_runs, & &1.id)

citations_to_remove =
  if length(section_run_ids) > 0 do
    ReportSectionCitation
    |> where([c], c.section_run_id in ^section_run_ids)
    |> Repo.all()
  else
    []
  end

IO.puts("Found #{length(citations_to_remove)} citations to remove")

# Step 4: Find parent report runs that might need updating
IO.puts("\n🔍 Step 4: Checking parent report runs...\n")

report_run_ids =
  problematic_runs
  |> Enum.map(& &1.report_run_id)
  |> Enum.uniq()
  |> Enum.reject(&is_nil/1)

parent_runs =
  if length(report_run_ids) > 0 do
    ReportRun
    |> where([r], r.id in ^report_run_ids)
    |> Repo.all()
  else
    []
  end

IO.puts("Found #{length(parent_runs)} parent report runs")

# Show summary
IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("  CLEANUP SUMMARY")
IO.puts(String.duplicate("=", 70) <> "\n")

IO.puts("Will remove:")
IO.puts("  • #{length(problematic_runs)} section runs with errors")
IO.puts("  • #{length(error_llm_invocations)} LLM invocations")
IO.puts("  • #{length(citations_to_remove)} citations")
IO.puts("")
IO.puts("Will keep:")
all_section_runs = Repo.aggregate(ReportSectionRun, :count)
all_llm_invocations = Repo.aggregate(LlmInvocation, :count)
all_citations = Repo.aggregate(ReportSectionCitation, :count)

IO.puts("  • #{all_section_runs - length(problematic_runs)} section runs (good ones)")
IO.puts("  • #{all_llm_invocations - length(error_llm_invocations)} LLM invocations")
IO.puts("  • #{all_citations - length(citations_to_remove)} citations")

if length(problematic_runs) == 0 do
  IO.puts("\n✓ Database is clean! Nothing to remove.")
  IO.puts("\n" <> String.duplicate("=", 70) <> "\n")
  System.halt(0)
end

# Confirmation
IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("  PROCEED WITH CLEANUP?")
IO.puts(String.duplicate("=", 70) <> "\n")

IO.puts("This will:")
IO.puts("  1. Delete #{length(citations_to_remove)} citations")
IO.puts("  2. Delete #{length(problematic_runs)} section runs")
IO.puts("  3. Delete #{length(error_llm_invocations)} LLM invocations")
IO.puts("  4. Keep all other data intact")
IO.puts("")
IO.puts("⚠️  This action cannot be undone!")
IO.puts("")
IO.puts("Proceed? (yes/no): ")

response = IO.gets("") |> String.trim() |> String.downcase()

if response != "yes" do
  IO.puts("\n❌ Cleanup cancelled. No changes made.")
  IO.puts("\n" <> String.duplicate("=", 70) <> "\n")
  System.halt(0)
end

# Execute cleanup in transaction
IO.puts("\n🔧 Executing cleanup...\n")

result =
  Repo.transaction(fn ->
    # Step 1: Delete citations
    if length(citations_to_remove) > 0 do
      citation_ids = Enum.map(citations_to_remove, & &1.id)

      {deleted, _} =
        Repo.delete_all(from(c in ReportSectionCitation, where: c.id in ^citation_ids))

      IO.puts("  ✓ Deleted #{deleted} citations")
    end

    # Step 2: Delete section runs
    if length(problematic_runs) > 0 do
      run_ids = Enum.map(problematic_runs, & &1.id)
      {deleted, _} = Repo.delete_all(from(r in ReportSectionRun, where: r.id in ^run_ids))
      IO.puts("  ✓ Deleted #{deleted} section runs")
    end

    # Step 3: Delete LLM invocations
    if length(error_llm_invocations) > 0 do
      llm_ids = Enum.map(error_llm_invocations, & &1.id)
      {deleted, _} = Repo.delete_all(from(l in LlmInvocation, where: l.id in ^llm_ids))
      IO.puts("  ✓ Deleted #{deleted} LLM invocations")
    end

    :ok
  end)

case result do
  {:ok, :ok} ->
    IO.puts("\n✅ Cleanup completed successfully!")
    IO.puts("")
    IO.puts("Next steps:")
    IO.puts("  1. Refresh the /reports page")
    IO.puts("  2. Click 'Run Section' or 'Run All Sections'")
    IO.puts("  3. The sections should generate without errors")
    IO.puts("")
    IO.puts("If you still see errors, they are NEW errors (not cached).")
    IO.puts("Run the diagnostic script to investigate:")
    IO.puts("  $ mix run examples/diagnose_schema_error.exs")

  {:error, reason} ->
    IO.puts("\n❌ Cleanup failed: #{inspect(reason)}")
    IO.puts("Database rolled back. No changes made.")
end

IO.puts("\n" <> String.duplicate("=", 70) <> "\n")
