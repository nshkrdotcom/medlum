defmodule Lumainus.Documents do
  @moduledoc """
  High-level helpers for managing document uploads and ingestion jobs.
  """

  import Ecto.Query, warn: false
  alias Lumainus.Accounts.Scope
  alias Lumainus.Documents.{DocumentUpload, IngestionJob}
  alias Lumainus.Repo
  alias Path

  def create_upload(%Scope{} = scope, patient, %{filename: filename} = metadata, binary) do
    digest = sha256(binary)

    attrs = %{
      tenant_id: scope.tenant_id,
      patient_id: patient.id,
      document_kind: "Clinical PDF",
      filename: filename,
      content_type: Map.get(metadata, :content_type) || "application/pdf",
      byte_size: Map.get(metadata, :byte_size, byte_size(binary)),
      sha256: digest,
      status: "pending",
      storage_backend: "postgres",
      metadata: %{
        "label" => Path.rootname(filename),
        "provider" => Map.get(metadata, :provider),
        "summary" => "Awaiting ingestion",
        "status" => "pending"
      },
      raw_blob: binary
    }

    %DocumentUpload{}
    |> DocumentUpload.changeset(attrs)
    |> Repo.insert()
  end

  def queue_ingestion(%DocumentUpload{} = upload, template, opts \\ []) do
    job =
      %IngestionJob{}
      |> IngestionJob.changeset(%{
        tenant_id: upload.tenant_id,
        upload_id: upload.id,
        job_type: "pdf_ingest",
        status: "pending",
        metadata: %{"template_id" => template.id},
        scheduled_at: DateTime.utc_now(:second)
      })
      |> Repo.insert!()

    processor = Keyword.get(opts, :processor, Lumainus.Documents.IngestionProcessor)

    Task.start(fn -> processor.process(job.id) end)

    {:ok, job}
  end

  defp sha256(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end
end
