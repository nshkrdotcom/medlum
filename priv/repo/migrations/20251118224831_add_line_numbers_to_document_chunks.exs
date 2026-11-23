defmodule Medlum.Repo.Migrations.AddLineNumbersToDocumentChunks do
  use Ecto.Migration

  def change do
    alter table(:document_chunks) do
      add(:line_start, :integer)
      add(:line_end, :integer)
      add(:page_number, :integer)
    end
  end
end
