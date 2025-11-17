defmodule Lumainus.Repo.Migrations.AddIngestionPromptToReportTemplates do
  use Ecto.Migration

  def change do
    alter table(:report_templates) do
      add(:ingestion_prompt_template, :text)
    end
  end
end
