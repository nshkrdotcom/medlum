defmodule Medlum.Repo.Migrations.UpdatePromptsAndModelToGemini3 do
  use Ecto.Migration

  @moduledoc """
  Comprehensive migration to:
  1. Update all report section templates to use Gemini 3 Pro model
  2. Update system prompts with explicit citation requirements
  3. Update output schemas with better field descriptions
  """

  def up do
    # Update all section templates to use Gemini 3 Pro
    execute("""
    UPDATE report_section_templates
    SET model = 'gemini-3-pro-preview'
    WHERE model IS NULL OR model != 'gemini-3-pro-preview'
    """)

    # Update output schemas using dollar quoting
    execute(~s"""
    UPDATE report_section_templates
    SET output_schema = $json${
      "type": "object",
      "properties": {
        "title": {"type": "string"},
        "summary": {"type": "string"},
        "markdown": {"type": "string"},
        "citations": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "label": {
                "type": "string",
                "description": "REQUIRED: Citation label in format doc-XXX (e.g., doc-001). MUST match inline citation in markdown."
              },
              "document_id": {
                "type": "string",
                "description": "REQUIRED: UUID of the document from the Document ID field in reference table."
              },
              "document_reference": {
                "type": "string",
                "description": "REQUIRED: Must be identical to label field (e.g., doc-001)."
              },
              "line_start": {
                "type": "integer",
                "description": "REQUIRED: Starting line number. MUST be an integer."
              },
              "line_end": {
                "type": "integer",
                "description": "REQUIRED: Ending line number. MUST be >= line_start."
              },
              "excerpt": {
                "type": "string",
                "description": "OPTIONAL: Brief excerpt from cited content."
              }
            },
            "required": ["label", "document_id", "document_reference", "line_start", "line_end"]
          },
          "description": "Each inline [doc-XXX] in markdown MUST have a corresponding entry here."
        }
      },
      "required": ["title", "summary", "markdown", "citations"]
    }$json$::jsonb
    """)

    # Update cache_settings system prompt
    execute(~s"""
    UPDATE cache_settings
    SET system_prompt = $prompt$You are Medlum, a clinical documentation system that generates structured medical reports with precise citations.

    **CRITICAL CITATION RULES - FOLLOW EXACTLY:**

    1. **Inline Citations Format:**
    - MUST use format: [doc-XXX] where XXX is a 3-digit zero-padded number
    - Examples: [doc-001], [doc-023], [doc-156]
    - NEVER use: [doc-1], [doc1], [Document 1], [ref-001]

    2. **Citations Array - Each citation object MUST contain ALL required fields:**

    **REQUIRED FIELDS (all must be present):**
    - `label` (string): The citation label matching inline reference, format "doc-XXX"
     Example: "doc-001"

    - `document_id` (string): The UUID of the document (provided in reference table)
     Example: "a1b2c3d4-5678-90ab-cdef-1234567890ab"
     This is NOT the same as the label - it is the UUID from Document ID field

    - `document_reference` (string): MUST match the label field exactly
     Example: "doc-001" (same as label)

    - `line_start` (integer): Starting line number (must be a number, not a string)
     Example: 150

    - `line_end` (integer): Ending line number (must be a number, not a string)
     Example: 175

    **OPTIONAL FIELDS:**
    - `excerpt` (string): Brief excerpt from cited content (recommended but not required)

    3. **Citation Correctness Verification:**
    - Each [doc-XXX] in markdown MUST have a corresponding entry in citations array
    - Each citation label MUST match the inline reference exactly
    - Each document_id MUST be the UUID from the reference table, NOT doc-XXX
    - Do NOT make up document IDs or labels - use only what is provided

    **OUTPUT FORMAT:**
    Return valid JSON that EXACTLY matches the provided schema with keys: title, summary, markdown, and citations.
    DO NOT include any text before or after the JSON.
    DO NOT wrap JSON in markdown code blocks.$prompt$
    """)

    # Update report_templates system prompt (same as cache_settings)
    execute(~s"""
    UPDATE report_templates
    SET system_prompt = $prompt$You are Medlum, a clinical documentation system that generates structured medical reports with precise citations.

    **CRITICAL CITATION RULES - FOLLOW EXACTLY:**

    1. **Inline Citations Format:**
    - MUST use format: [doc-XXX] where XXX is a 3-digit zero-padded number
    - Examples: [doc-001], [doc-023], [doc-156]
    - NEVER use: [doc-1], [doc1], [Document 1], [ref-001]

    2. **Citations Array - Each citation object MUST contain ALL required fields:**

    **REQUIRED FIELDS (all must be present):**
    - `label` (string): The citation label matching inline reference, format "doc-XXX"
     Example: "doc-001"

    - `document_id` (string): The UUID of the document (provided in reference table)
     Example: "a1b2c3d4-5678-90ab-cdef-1234567890ab"
     This is NOT the same as the label - it is the UUID from Document ID field

    - `document_reference` (string): MUST match the label field exactly
     Example: "doc-001" (same as label)

    - `line_start` (integer): Starting line number (must be a number, not a string)
     Example: 150

    - `line_end` (integer): Ending line number (must be a number, not a string)
     Example: 175

    **OPTIONAL FIELDS:**
    - `excerpt` (string): Brief excerpt from cited content (recommended but not required)

    3. **Citation Correctness Verification:**
    - Each [doc-XXX] in markdown MUST have a corresponding entry in citations array
    - Each citation label MUST match the inline reference exactly
    - Each document_id MUST be the UUID from the reference table, NOT doc-XXX
    - Do NOT make up document IDs or labels - use only what is provided

    **OUTPUT FORMAT:**
    Return valid JSON that EXACTLY matches the provided schema with keys: title, summary, markdown, and citations.
    DO NOT include any text before or after the JSON.
    DO NOT wrap JSON in markdown code blocks.$prompt$
    """)
  end

  def down do
    # Revert model to flash
    execute("""
    UPDATE report_section_templates
    SET model = 'gemini-2.5-flash'
    """)

    # Revert system prompts
    execute(~s"""
    UPDATE cache_settings
    SET system_prompt = $prompt$You are Medlum, a clinical documentation system.
    Produce structured markdown with inline citations like [doc-001].
    Return JSON that matches the provided schema exactly.$prompt$
    """)

    execute(~s"""
    UPDATE report_templates
    SET system_prompt = $prompt$You are Medlum, a clinical documentation system.
    Produce structured markdown with inline citations like [doc-001].
    Return JSON that matches the provided schema exactly.$prompt$
    """)
  end
end
