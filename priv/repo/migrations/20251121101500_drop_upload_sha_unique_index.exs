defmodule Medlum.Repo.Migrations.DropUploadShaUniqueIndex do
  use Ecto.Migration

  def change do
    drop_if_exists(unique_index(:document_uploads, [:tenant_id, :sha256]))
  end
end
