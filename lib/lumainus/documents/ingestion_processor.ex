defmodule Lumainus.Documents.IngestionProcessor do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Lumainus.Docling
  alias Lumainus.Documents
  alias Lumainus.Documents.{DocumentChunk, DocumentParse, DocumentUpload, IngestionJob}
  alias Lumainus.Clinical.PatientProfile
  alias Lumainus.Repo

  def process(job_id) do
    job =
      IngestionJob
      |> Repo.get!(job_id)
      |> Repo.preload(upload: [:patient, :record_set])

    job = mark_processing(job)

    result =
      with {:ok, response, job} <- docling_convert(job),
           {:ok, _parse, job} <- persist_parse(job, response) do
        {:ok, job}
      else
        {:error, reason, job} -> {:error, reason, job}
      end

    case result do
      {:ok, job} ->
        finalize_job(job, :ok)
        :ok

      {:error, reason, job} ->
        finalize_job(job, {:error, reason})
        {:error, reason}
    end
  end

  defp mark_processing(job) do
    job =
      job
      |> Changeset.change(%{status: "processing", started_at: DateTime.utc_now(:second)})
      |> Repo.update!()
      |> Map.put(:upload, job.upload)

    {job, _event} =
      Documents.record_job_stage!(
        job,
        "downloading",
        message: "Preparing upload for Docling",
        progress: 15
      )

    job
  end

  defp docling_convert(%IngestionJob{} = job) do
    timeout_ms = Docling.timeout()

    timeout_at =
      DateTime.utc_now(:second)
      |> DateTime.add(div(timeout_ms, 1000), :second)

    {job, _event} =
      Documents.record_job_stage!(
        job,
        "docling",
        message: "Sending binary to Docling service",
        progress: 50,
        timeout_at: timeout_at,
        payload: %{timeout_at: timeout_at}
      )

    upload = job.upload

    case Docling.convert(upload.raw_blob,
           filename: upload.filename,
           content_type: upload.content_type,
           byte_size: upload.byte_size,
           upload_id: upload.id,
           job_id: job.id
         ) do
      {:ok, response} -> {:ok, response, job}
      {:error, reason} -> {:error, reason, job}
    end
  end

  defp persist_parse(%IngestionJob{} = job, response) do
    {job, _event} =
      Documents.record_job_stage!(
        job,
        "parsing",
        message: "Persisting Docling response",
        progress: 80
      )

    upload = job.upload

    markdown =
      response
      |> fetch_markdown()
      |> cleanse_markdown()

    metadata = response["metadata"] || %{}

    parse =
      %DocumentParse{}
      |> DocumentParse.changeset(%{
        upload_id: upload.id,
        parser: "docling",
        parsed_text: markdown,
        structured_metadata: response,
        extracted_at: DateTime.utc_now(:second),
        patient_profile_id: upload.patient && upload.patient.current_profile_id
      })
      |> Repo.insert!()

    persist_chunks(parse, markdown)

    maybe_update_patient(upload, response)
    refresh_upload_metadata(upload, markdown, metadata)
    {:ok, parse, job}
  end

  defp refresh_upload_metadata(upload, markdown, docling_metadata) do
    summary = short_summary(markdown)

    updated_metadata =
      (upload.metadata || %{})
      |> Map.put("summary", summary)
      |> Map.put("status", "parsed")
      |> Map.put("ingestion_stage", "completed")
      |> Map.put("ingestion_progress", 100)
      |> Map.put("ingestion_message", "Docling ingestion finished")
      |> Map.put("page_count", docling_metadata["page_count"])
      |> Map.put("source_kind", docling_metadata["source_kind"])
      |> Map.put("has_tables", docling_metadata["has_tables"])

    upload
    |> Changeset.change(%{
      status: "parsed",
      metadata: updated_metadata,
      ingested_at: DateTime.utc_now(:second)
    })
    |> Repo.update!()

    Documents.notify_documents_changed(upload.record_set_id)
  end

  defp maybe_update_patient(%DocumentUpload{patient: nil}, _response), do: :ok

  defp maybe_update_patient(%DocumentUpload{patient: patient}, response) do
    profile = patient.current_profile && Repo.preload(patient, :current_profile).current_profile

    if profile do
      attrs =
        %{
          structured_metadata:
            Map.merge(profile.structured_metadata || %{}, %{"docling" => response})
        }

      profile
      |> PatientProfile.changeset(attrs)
      |> Repo.update()
    else
      :ok
    end
  end

  defp finalize_job(job, :ok) do
    job =
      job
      |> Changeset.change(%{status: "completed", finished_at: DateTime.utc_now(:second)})
      |> Repo.update!()
      |> Map.put(:upload, job.upload)

    Documents.record_job_stage!(
      job,
      "completed",
      message: "Docling ingestion finished",
      progress: 100
    )
  end

  defp finalize_job(job, {:error, reason}) do
    job =
      job
      |> Changeset.change(%{
        status: "failed",
        finished_at: DateTime.utc_now(:second),
        error: %{message: inspect(reason)}
      })
      |> Repo.update!()
      |> Map.put(:upload, job.upload)

    Documents.record_job_stage!(
      job,
      "failed",
      message: "Docling ingestion failed: #{inspect(reason)}",
      upload_status: "failed"
    )
  end

  defp short_summary(markdown) when is_binary(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(3)
    |> Enum.join(" ")
    |> String.slice(0, 280)
    |> case do
      <<>> -> "Awaiting summarization"
      text -> text
    end
  end

  defp short_summary(_), do: "Awaiting summarization"

  defp persist_chunks(parse, markdown) when is_binary(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce(0, fn {line, line_number}, position ->
      trimmed = String.trim(line)

      if trimmed == "" do
        position
      else
        %DocumentChunk{}
        |> DocumentChunk.changeset(%{
          parse_id: parse.id,
          position: position,
          content: line,
          token_count: trimmed |> String.split() |> length(),
          line_start: line_number,
          line_end: line_number
        })
        |> Repo.insert!()

        position + 1
      end
    end)

    :ok
  end

  defp persist_chunks(_parse, _markdown), do: :ok

  defp fetch_markdown(response) when is_map(response) do
    case Map.get(response, "markdown") do
      nil -> ""
      value when is_binary(value) -> value
      other -> to_string(other)
    end
  end

  defp fetch_markdown(_), do: ""

  defp cleanse_markdown(content) do
    content
    |> String.replace(~r/<!--\s*image\s*-->/i, "")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
