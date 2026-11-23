defmodule Medlum.Repo.Migrations.AddFinishReasonToLlmInvocations do
  use Ecto.Migration

  def change do
    alter table(:llm_invocations) do
      # Gemini finish_reason: STOP, MAX_TOKENS, SAFETY, RECITATION, OTHER, etc.
      add(:finish_reason, :string)

      # Whether content was present in the response
      add(:has_content, :boolean, default: true)

      # Number of parts in the response
      add(:parts_count, :integer)
    end

    # Index for querying by finish_reason (useful for debugging)
    create(index(:llm_invocations, [:finish_reason]))
  end
end
