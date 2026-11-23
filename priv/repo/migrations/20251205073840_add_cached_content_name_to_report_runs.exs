defmodule Medlum.Repo.Migrations.AddCachedContentNameToReportRuns do
  use Ecto.Migration

  def change do
    alter table(:report_runs) do
      # Gemini context cache name for shared document context across sections
      # Format: "cachedContents/{id}" or full Vertex AI path
      add(:cached_content_name, :string)
    end
  end
end
