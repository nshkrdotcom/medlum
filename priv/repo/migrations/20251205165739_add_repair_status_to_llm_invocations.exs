defmodule Lumainus.Repo.Migrations.AddRepairStatusToLlmInvocations do
  use Ecto.Migration

  def change do
    alter table(:llm_invocations) do
      add(:repair_status, :string, default: "none", null: false)
    end

    create(
      constraint(:llm_invocations, :valid_repair_status,
        check: "repair_status IN ('none', 'repaired', 'failed')"
      )
    )
  end
end
