# Clear old report section runs that have errors
#
# The error you're seeing might be from old cached runs in the database
# Run with: mix run examples/clear_old_runs.exs

alias Lumainus.Repo
alias Lumainus.Reports.{ReportRun, ReportSectionRun}
import Ecto.Query

IO.puts("\n=== Checking Old Report Runs ===\n")

# Find all section runs with errors
error_runs =
  ReportSectionRun
  |> where([r], not is_nil(r.error))
  |> Repo.all()

IO.puts("Found #{length(error_runs)} section runs with errors")

if length(error_runs) > 0 do
  IO.puts("")
  IO.puts("Error details:")

  for run <- Enum.take(error_runs, 5) do
    error_msg = run.error["message"] || inspect(run.error)
    truncated = String.slice(error_msg, 0, 200)
    IO.puts("  - #{truncated}#{if String.length(error_msg) > 200, do: "...", else: ""}")

    # Check if it's a ReqLLM error
    if String.contains?(error_msg, "ReqLLM") or String.contains?(error_msg, "items") do
      IO.puts("    ⚠️  This looks like the ReqLLM schema validation error!")
    end
  end

  if length(error_runs) > 5 do
    IO.puts("  ... and #{length(error_runs) - 5} more")
  end

  IO.puts("")
  IO.puts("Do you want to delete these old error runs? (y/N)")
  response = IO.gets("") |> String.trim() |> String.downcase()

  if response == "y" or response == "yes" do
    deleted_count = Repo.delete_all(from(r in ReportSectionRun, where: not is_nil(r.error)))
    IO.puts("✓ Deleted #{deleted_count} error runs")
  else
    IO.puts("Skipping deletion")
  end
else
  IO.puts("✓ No error runs found!")
end

IO.puts("")

# Also check for any runs with status "error"
status_error_runs =
  ReportSectionRun
  |> where([r], r.status == "error")
  |> Repo.all()

if length(status_error_runs) > 0 do
  IO.puts("Found #{length(status_error_runs)} runs with status='error'")
  IO.puts("")
  IO.puts("Clear these as well? (y/N)")
  response = IO.gets("") |> String.trim() |> String.downcase()

  if response == "y" or response == "yes" do
    deleted_count = Repo.delete_all(from(r in ReportSectionRun, where: r.status == "error"))
    IO.puts("✓ Deleted #{deleted_count} error status runs")
  end
end

IO.puts("\n=== Done ===\n")
IO.puts("Now try running a section again to see if it works!")
IO.puts("")
