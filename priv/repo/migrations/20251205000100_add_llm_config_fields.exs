defmodule Lumainus.Repo.Migrations.AddLlmConfigFields do
  @moduledoc """
  Add comprehensive LLM configuration fields to report_section_templates and report_templates.

  This migration adds per-section fields for:
  - Sampling parameters (top_p, top_k, candidate_count)
  - Penalty parameters (presence_penalty, frequency_penalty)
  - Control parameters (stop_sequences, seed)
  - Context (system_prompt)
  - Reliability (timeout_ms, max_retries, retry_delay_ms)
  - Fallback (fallback_provider, fallback_model)
  - Response format (response_mime_type)

  Template-level system_prompt is also added for default prompts.

  Constraints enforce valid value ranges per Gemini API specifications.
  """
  use Ecto.Migration

  def change do
    alter table(:report_section_templates) do
      # Sampling parameters
      add(:top_p, :float)
      add(:top_k, :integer)
      add(:candidate_count, :integer, default: 1)

      # Penalty parameters
      add(:presence_penalty, :float)
      add(:frequency_penalty, :float)

      # Control parameters
      add(:stop_sequences, {:array, :string}, default: [])
      add(:seed, :integer)

      # Context
      add(:system_prompt, :text)

      # Reliability
      add(:timeout_ms, :integer, default: 120_000)
      add(:max_retries, :integer, default: 3)
      add(:retry_delay_ms, :integer, default: 1000)

      # Fallback
      add(:fallback_provider, :string)
      add(:fallback_model, :string)

      # Response format / mime
      add(:response_mime_type, :string, default: "application/json")
    end

    alter table(:report_templates) do
      add(:system_prompt, :text)
    end

    # Constraints for valid value ranges
    # Temperature: 0.0 to 2.0 (already exists on table but add constraint)
    create(
      constraint(:report_section_templates, :temperature_range,
        check: "temperature IS NULL OR (temperature >= 0.0 AND temperature <= 2.0)"
      )
    )

    # Top P: 0.0 to 1.0
    create(
      constraint(:report_section_templates, :top_p_range,
        check: "top_p IS NULL OR (top_p >= 0.0 AND top_p <= 1.0)"
      )
    )

    # Penalties: -2.0 to 2.0
    create(
      constraint(:report_section_templates, :penalty_range,
        check:
          "(presence_penalty IS NULL OR (presence_penalty >= -2.0 AND presence_penalty <= 2.0)) AND " <>
            "(frequency_penalty IS NULL OR (frequency_penalty >= -2.0 AND frequency_penalty <= 2.0))"
      )
    )

    # Candidate count: >= 1
    create(
      constraint(:report_section_templates, :candidate_count_positive,
        check: "candidate_count IS NULL OR candidate_count >= 1"
      )
    )

    # Top K: >= 0
    create(
      constraint(:report_section_templates, :top_k_non_negative,
        check: "top_k IS NULL OR top_k >= 0"
      )
    )

    # Timeout: > 0
    create(
      constraint(:report_section_templates, :timeout_positive,
        check: "timeout_ms IS NULL OR timeout_ms > 0"
      )
    )

    # Retries: >= 0
    create(
      constraint(:report_section_templates, :retry_non_negative,
        check: "max_retries IS NULL OR max_retries >= 0"
      )
    )
  end
end
