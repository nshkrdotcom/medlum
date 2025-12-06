alias Lumainus.Repo
alias Lumainus.Reports.{ReportRun, ReportSectionRun, CacheSettings}
import Ecto.Query

IO.puts("=== Exporting Debug Data ===\n")

# Get the latest report run
latest_run =
  Repo.one(
    from(r in ReportRun,
      where: not is_nil(r.cached_content_name),
      order_by: [desc: r.inserted_at],
      limit: 1,
      preload: [:template]
    )
  )

IO.puts("Report Run: #{latest_run.id}")
IO.puts("Cache Name: #{latest_run.cached_content_name}")

# Get system prompt from template
system_prompt = latest_run.template.system_prompt || "You are a medical AI assistant."
File.write!("/home/home/p/g/n/gemini_ex/debug/system_prompt.txt", system_prompt)

# Get a failed section
failed_section =
  Repo.one(
    from(s in ReportSectionRun,
      join: t in assoc(s, :section_template),
      join: li in assoc(s, :llm_invocation),
      where: s.report_run_id == ^latest_run.id,
      where: is_nil(li.response_text) or li.response_text == "",
      limit: 1,
      preload: [section_template: t, llm_invocation: li]
    )
  )

# Get model and settings
model = CacheSettings.cache_model()
IO.puts("Model: #{model}")

if failed_section do
  IO.puts("Failed section: #{failed_section.section_template.title}")

  # Write output schema
  schema = failed_section.section_template.output_schema
  schema_json = if schema, do: Jason.encode!(schema, pretty: true), else: "{}"
  File.write!("/home/home/p/g/n/gemini_ex/debug/output_schema.json", schema_json)

  # Write prompt template
  File.write!(
    "/home/home/p/g/n/gemini_ex/debug/prompt_template.txt",
    failed_section.section_template.prompt_template || ""
  )

  # Write the actual prompt used
  prompt_inputs = failed_section.llm_invocation.prompt_context || %{}

  File.write!(
    "/home/home/p/g/n/gemini_ex/debug/actual_prompt.txt",
    failed_section.llm_invocation.prompt_text || ""
  )

  # Write metadata
  metadata = %{
    model: model,
    cache_name: latest_run.cached_content_name,
    section_title: failed_section.section_template.title,
    temperature: failed_section.section_template.temperature,
    max_output_tokens: failed_section.section_template.max_output_tokens,
    llm_invocation_id: failed_section.llm_invocation.id,
    llm_status: failed_section.llm_invocation.status,
    llm_usage: failed_section.llm_invocation.usage
  }

  File.write!(
    "/home/home/p/g/n/gemini_ex/debug/metadata.json",
    Jason.encode!(metadata, pretty: true)
  )

  IO.puts("\nFiles written to /home/home/p/g/n/gemini_ex/debug/")
  IO.puts("  - system_prompt.txt")
  IO.puts("  - output_schema.json")
  IO.puts("  - prompt_template.txt")
  IO.puts("  - actual_prompt.txt")
  IO.puts("  - metadata.json")
else
  IO.puts("No failed sections found")
end
