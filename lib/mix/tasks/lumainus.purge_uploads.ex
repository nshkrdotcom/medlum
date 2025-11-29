defmodule Mix.Tasks.Lumainus.PurgeUploads do
  @moduledoc """
  Deletes all document uploads (and cascading parses/ingestion jobs) so you can start fresh.

  Run with:

      mix lumainus.purge_uploads
  """

  use Mix.Task

  @shortdoc "Deletes all document uploads and related ingestion artifacts"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start", [])

    {deleted, _} =
      Lumainus.Documents.DocumentUpload
      |> Lumainus.Repo.delete_all()

    Mix.shell().info("Removed #{deleted} document upload(s).")
  end
end
