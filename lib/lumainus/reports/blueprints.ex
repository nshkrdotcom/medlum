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
        title: "History of Present Illness (HPI)",
        focus: "a chronological narrative of the presenting problem",
        instructions: hpi_instructions()
      },
      %{
        identifier: "past-history",
        title: "Past History",
        focus: "medical, surgical, and social history summaries",
        instructions: past_history_instructions()
      },
      %{
        identifier: "medications",
        title: "Medications",
        focus: "current medications, doses, and adherence notes",
        instructions: medications_instructions()
      },
      %{
        identifier: "physical-exam-history",
        title: "Past Physical Exam Findings",
        focus: "historical exam findings and vitals trends",
        instructions: physical_exam_instructions()
      },
      %{
        identifier: "review-of-systems",
        title: "Review of Systems",
        focus: "prior documented ROS results",
        instructions: ros_instructions()
      },
      %{
        identifier: "lab-review",
        title: "Laboratory Review",
        focus: "all relevant laboratory data and trends",
        instructions: lab_review_instructions()
      },
      %{
        identifier: "imaging-review",
        title: "Imaging Review",
        focus: "radiology, cardiology, and other imaging summaries",
        instructions: imaging_review_instructions()
      },
      %{
        identifier: "pathology-review",
        title: "Pathology Review",
        focus: "biopsy and pathology results relevant to the case",
        instructions: pathology_review_instructions()
      },
      %{
        identifier: "assessment",
        title: "Assessment",
        focus: "synthesis of clinical problems with evidence",
        instructions: assessment_instructions()
      },
      %{
        identifier: "plan",
        title: "Plan",
        focus: "recommended management steps for each assessed problem",
        instructions: plan_instructions()
      }
    ]
  end

  @doc """
  Returns the list of section identifiers.
  """
  def section_identifiers do
    Enum.map(section_blueprints(), & &1.identifier)
  end

  @doc """
  Default JSON Schema for structured section output.

  This schema defines the expected output format from the LLM:
  - title: Section title
  - summary: Brief summary of the section content
  - markdown: Full markdown content with inline citations
  - citations: List of citation references with document IDs
  """
  def default_output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "summary" => %{"type" => "string"},
        "markdown" => %{"type" => "string"},
        "citations" => %{
          "type" => "array",
          "items" => citations_item_schema(),
          "description" => "List of citations with label and document_id"
        }
      },
      "required" => ["title", "summary", "markdown", "citations"]
    }
  end

  @doc """
  Schema for individual citation items in the citations array.
  """
  def citations_item_schema do
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

  @doc """
  Default prompt for PDF ingestion/normalization.

  This prompt instructs the LLM how to convert uploaded PDFs
  into structured markdown summaries for use in report generation.
  """
  def default_ingestion_prompt do
    """
    You convert uploaded medical PDFs into structured markdown summaries.

    - Read all textual content and preserve its order.
    - Emit markdown with headings (##) for major sections you detect.
    - Keep bullet lists when possible.
    - Extract patient name and MRN if available. If missing, return "Unknown".
    - Capture a short summary paragraph (2-3 sentences) highlighting key facts.
    - Do not include commentary about being an AI.
    """
  end

  @doc """
  Default template attributes for new tenants.
  """
  def default_template_attrs do
    %{
      name: "Cardiology Intake",
      slug: "cardiology-primary",
      description: "LLM-driven cardiology intake report with 11 clinical sections"
    }
  end

  @doc """
  Default system prompt for LLM interactions.

  This prompt sets the overall behavior and output format expectations.
  It's stored in the database at the template level and can be overridden per-section.
  """
  def default_system_prompt do
    """
    You are Lumainus, a clinical documentation system.
    Produce structured markdown with inline citations like [doc-001].
    Return JSON that matches the provided schema exactly.
    """
  end

  @doc """
  Generate section prompt from focus and optional instructions.

  This function creates the user prompt template that will be sent to the LLM.
  The template uses EEx syntax and expects the following assigns:
  - section_title: The title of the section
  - patient: Patient struct with full_name, mrn, date_of_birth
  - documents: List of document payloads
  - documents_summary: Summary of documents
  - documents_text: Full text of documents with line references
  """
  def section_prompt(focus, opts \\ []) do
    instructions_block =
      opts
      |> Keyword.get(:instructions)
      |> case do
        nil ->
          ""

        text ->
          trimmed = String.trim(text)

          """

          Clinical formatting guidance:
          #{trimmed}
          """
      end

    """
    You are drafting the <%= section_title %> portion of a cardiology report focused on #{focus}.
    Patient: <%= patient.full_name %> (MRN <%= patient.mrn %>, DOB <%= patient.date_of_birth %>)

    Cite source evidence using the document IDs below. Inline citations must use the mock ID (e.g., [doc-101])
    and each citation entry in the structured JSON output must include the matching `document_id` value.

    #{instructions_block}

    Document reference table:
    <%= for doc <- documents do %>
    - <%= doc["mock_id"] || doc["label"] %>: Document ID <%= doc["id"] %> · <%= doc["summary"] %>
    <% end %>

    Summaries:
    <%= documents_summary %>

    Source content:
    <%= documents_text %>

    Return JSON that matches the provided schema with keys `title`, `summary`, `markdown`, and `citations`.
    The markdown must include inline citations matching `[mock_id]`. Each citation entry must provide
    `label`, `document_id`, `document_reference`, `line_start`, `line_end`, and a short `excerpt`.
    """
  end

  # Private instruction functions for each section type

  defp cc_instructions do
    """
    - Keep this section to 1-2 sentences written from the patient's voice.
    - Capture onset timing, severity, and precipitating context if documented.
    - Highlight notable quotes or descriptors inside quotation marks.
    """
  end

  defp hpi_instructions do
    """
    - Organize paragraphs by timeline: onset, progression, current status.
    - Mention alleviating/exacerbating factors plus associated ROS findings.
    - Call out pertinent negatives inline (e.g., \"denies syncope\").
    """
  end

  defp past_history_instructions do
    """
    - Create subheadings for Medical History, Surgical History, and Social History.
    - Use bullet lists under each subheading; include dates if available.
    - Social History should mention marital status, tobacco/alcohol/drugs, and occupation when documented.
    """
  end

  defp medications_instructions do
    """
    - Present as a bullet list with medication name, dose, route, and frequency.
    - Note recent changes, held meds, or adherence concerns in italics.
    - Include OTC and supplements if present.
    """
  end

  defp physical_exam_instructions do
    """
    - Group content by system (Cardiovascular, Pulmonary, Neuro, etc.) with subheadings.
    - Highlight abnormal findings first, then list reassuring normals.
    - Include notable vital trends with dates.
    """
  end

  defp ros_instructions do
    """
    - Use a table or bullet list grouped by system.
    - For each system, list positives first then key negatives.
    - Limit to items explicitly mentioned in the source documents.
    """
  end

  defp lab_review_instructions do
    """
    - Provide a markdown table with columns: Test, Value & Units, Reference/Flag, Date or Trend.
    - Call out abnormal values with **bold** flags or text.
    - Follow the table with 1-2 sentences interpreting the trends.
    """
  end

  defp imaging_review_instructions do
    """
    - List each study with modality and date.
    - Summarize impressions plus key measurements (e.g., EF, stenosis %).
    - Note whether follow-up imaging is pending.
    """
  end

  defp pathology_review_instructions do
    """
    - Include specimen site, diagnosis, grade/stage markers, and critical molecular findings.
    - Mention when pathology is pending or inconclusive.
    - Tie findings to treatment implications when evident.
    """
  end

  defp assessment_instructions do
    """
    - Use a numbered list, one problem per number ordered by priority.
    - Each entry should include 1-2 sentences referencing supporting data with citations.
    - Note current status/severity and clinical uncertainty if present.
    """
  end

  defp plan_instructions do
    """
    - Mirror the numbering from the Assessment section when possible.
    - Detail medications, procedures, monitoring, patient education, and contingency plans.
    - Include follow-up steps and responsible teams.
    """
  end
end
