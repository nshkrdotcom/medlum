defmodule Lumainus.Repo.Migrations.AddGemini064FieldsToLlmInvocations do
  use Ecto.Migration

  @doc """
  Adds new fields from gemini_ex 0.6.4 to llm_invocations for better tracking/debugging.

  - response_id: Unique response identifier from Gemini API
  - model_version: Actual model version used (e.g., "gemini-2.5-flash-001")
  - finish_message: Human-readable message explaining why the model stopped
  - thoughts_token_count: Token count for thinking (Gemini 2.5+ models)
  - traffic_type: Billing traffic type (on_demand, provisioned_throughput)
  """
  def change do
    alter table(:llm_invocations) do
      add(:response_id, :string)
      add(:model_version, :string)
      add(:finish_message, :text)
      add(:thoughts_token_count, :integer)
      add(:traffic_type, :string)
    end

    create(index(:llm_invocations, [:response_id]))
    create(index(:llm_invocations, [:model_version]))
  end
end
