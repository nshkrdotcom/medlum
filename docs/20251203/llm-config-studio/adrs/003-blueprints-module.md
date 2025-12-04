# ADR-003: Blueprints Module Extraction

## Status
Proposed

## Context

The 11 report section definitions are currently buried in `lib/lumainus/reports.ex` (lines 637-750), mixed with business logic. The user wants these to remain hard-coded but in a "clean and obvious" location.

Current problems:
- Blueprints scattered across multiple private functions
- Mixed with 800+ lines of query/transaction logic
- Not immediately discoverable for new developers
- No clear separation between "template structure" and "configurable settings"

## Decision

Extract all blueprint-related code to a dedicated module: `lib/lumainus/reports/blueprints.ex`

### New Module Structure

```elixir
defmodule Lumainus.Reports.Blueprints do
  @moduledoc """
  Hard-coded report section blueprints and template definitions.

  These blueprints define the structure of the default "Cardiology Intake" report.
  They are the source of truth for:
  - Section identifiers and display names
  - Clinical focus statements
  - Clinical formatting instructions
  - Default output schema structure

  While section structure is hard-coded, LLM configuration (model, temperature, etc.)
  and prompts are stored in the database and customizable per tenant via the UI.

  ## The 11 Sections

  1. chief-complaint - Primary reason for presentation
  2. history-present-illness - Timeline and symptom progression
  3. past-history - Medical, surgical, family history
  4. medications - Current medications and allergies
  5. physical-exam-history - Past physical examination findings
  6. review-of-systems - Systematic symptom review
  7. lab-review - Laboratory results analysis
  8. imaging-review - Imaging studies interpretation
  9. pathology-review - Pathology reports analysis
  10. assessment - Clinical assessment and diagnoses
  11. plan - Treatment plan and recommendations
  """

  @doc """
  Returns the list of section blueprints.

  Each blueprint contains:
  - `identifier` - Unique kebab-case key (referenced in code/migrations)
  - `title` - Human-readable display name
  - `focus` - Clinical focus statement for prompt generation
  - `instructions` - Detailed formatting guidance
  """
  def section_blueprints do
    [
      %{
        identifier: "chief-complaint",
        title: "Chief Complaint",
        focus: "the patient's primary reason for presentation",
        instructions: cc_instructions()
      },
      %{
        identifier: "history-present-illness",
        title: "History of Present Illness",
        focus: "chronological narrative of symptom development",
        instructions: hpi_instructions()
      },
      # ... remaining 9 sections
    ]
  end

  @doc "Default JSON Schema for structured section output"
  def default_output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "summary" => %{"type" => "string"},
        "markdown" => %{"type" => "string"},
        "citations" => %{
          "type" => "array",
          "items" => citations_schema()
        }
      },
      "required" => ["title", "summary", "markdown", "citations"]
    }
  end

  @doc "Default prompt for PDF ingestion/normalization"
  def default_ingestion_prompt do
    """
    You are a medical document processor...
    """
  end

  @doc "Default template attributes for new tenants"
  def default_template_attrs do
    %{
      name: "Cardiology Intake",
      slug: "cardiology-primary",
      description: "LLM-driven cardiology intake report with 11 clinical sections"
    }
  end

  @doc "Generate section prompt from focus and instructions"
  def section_prompt(focus, opts \\ []) do
    instructions = Keyword.get(opts, :instructions, "")
    # EEx template generation...
  end

  # Private instruction functions for each section type
  defp cc_instructions, do: "..."
  defp hpi_instructions, do: "..."
  # etc.
end
```

### Updates to `reports.ex`

```elixir
defmodule Lumainus.Reports do
  alias Lumainus.Reports.Blueprints

  def default_sections(template_id) do
    Blueprints.section_blueprints()
    |> Enum.with_index(1)
    |> Enum.map(fn {blueprint, idx} ->
      %{
        identifier: blueprint.identifier,
        title: blueprint.title,
        prompt_template: Blueprints.section_prompt(blueprint.focus,
          instructions: blueprint.instructions),
        output_schema: Blueprints.default_output_schema(),
        template_id: template_id,
        position: idx * 10
      }
    end)
  end

  def ensure_template!(scope) do
    # ... uses Blueprints.default_template_attrs()
    # ... uses Blueprints.default_ingestion_prompt()
  end
end
```

### File Organization

```
lib/lumainus/reports/
├── blueprints.ex          # NEW - Hard-coded section definitions
├── report_template.ex     # Schema
├── report_section_template.ex  # Schema
├── report_run.ex          # Schema
├── report_section_run.ex  # Schema
└── ... other schemas

lib/lumainus/reports.ex    # Context module (streamlined)
```

## Consequences

### Positive
- Single, obvious location for blueprints
- Extensive documentation in one place
- Clear separation: blueprints vs business logic
- Easy to version or add alternative templates later
- `reports.ex` reduced by ~150 lines

### Negative
- One more module to maintain
- Need to update imports in existing code

### Migration Path
1. Create `blueprints.ex` with extracted code
2. Update `reports.ex` to alias and call Blueprints
3. Update migrations to use `Blueprints` if needed
4. No database changes required
