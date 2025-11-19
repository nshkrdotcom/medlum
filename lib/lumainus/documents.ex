defmodule Lumainus.Documents do
  @moduledoc """
  High-level helpers for managing document uploads and ingestion jobs.
  """

  import Ecto.Query, warn: false
  alias Ecto.Changeset
  alias Lumainus.Accounts.Scope

  alias Lumainus.Documents.{
    DoclingIngestionWorker,
    DocumentChunk,
    DocumentParse,
    DocumentUpload,
    IngestionEvent,
    IngestionJob,
    SampleData
  }

  alias Lumainus.Repo
  alias Oban
  alias Path
  alias Phoenix.PubSub
  require Logger

  @topic_prefix "record-set"
  @job_topic_prefix "ingestion-job"

  def subscribe_to_record_set(record_set_id) when is_binary(record_set_id) do
    PubSub.subscribe(LumainusWeb.PubSub, topic(record_set_id))
  end

  def subscribe_to_ingestion_job(job_id) when is_binary(job_id) do
    PubSub.subscribe(LumainusWeb.PubSub, job_topic(job_id))
  end

  def notify_documents_changed(record_set_id) when is_binary(record_set_id) do
    PubSub.broadcast(
      LumainusWeb.PubSub,
      topic(record_set_id),
      {:documents_changed, record_set_id}
    )
  end

  def notify_job_progress(%IngestionJob{} = job, event \\ nil) do
    payload =
      %{
        job_id: job.id,
        upload_id: job.upload_id,
        record_set_id: job.record_set_id,
        status: job.status,
        stage: job.stage,
        progress: job.progress,
        last_message: job.last_message,
        started_at: job.started_at,
        finished_at: job.finished_at,
        updated_at: job.updated_at
      }
      |> maybe_attach_event(event)

    PubSub.broadcast(
      LumainusWeb.PubSub,
      job_topic(job.id),
      {:job_progress, job.record_set_id, payload}
    )
  end

  def create_upload(
        %Scope{} = scope,
        patient,
        record_set,
        %{filename: filename} = metadata,
        binary
      ) do
    digest = sha256(binary)

    attrs = %{
      tenant_id: scope.tenant_id,
      patient_id: patient.id,
      record_set_id: record_set.id,
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

    case maybe_insert_upload(attrs) do
      {:ok, upload} = result ->
        Logger.info("Created upload #{upload.id} for record set #{upload.record_set_id}")
        notify_documents_changed(upload.record_set_id)
        result

      error ->
        error
    end
  end

  def seed_sample_documents(%Scope{} = scope, patient, record_set) do
    now = DateTime.utc_now(:second)

    inserted =
      SampleData.samples()
      |> Enum.reduce([], fn sample, acc ->
        case ensure_sample_document(scope, patient, record_set, sample, now) do
          {:ok, upload} -> [upload | acc]
          {:skip, _} -> acc
        end
      end)

    case inserted do
      [] ->
        {:ok, :noop}

      uploads ->
        notify_documents_changed(record_set.id)
        {:ok, Enum.reverse(uploads)}
    end
  end

  defp maybe_insert_upload(attrs) do
    tenant_id = attrs.tenant_id
    record_set_id = attrs.record_set_id
    sha = attrs.sha256

    case duplicate_upload(tenant_id, record_set_id, sha) do
      nil ->
        %DocumentUpload{}
        |> DocumentUpload.changeset(attrs)
        |> Repo.insert()

      upload ->
        {:error, {:duplicate, upload}}
    end
  end

  defp ensure_sample_document(scope, patient, record_set, sample, timestamp) do
    existing =
      DocumentUpload
      |> where([d], d.record_set_id == ^record_set.id)
      |> where([d], fragment("?->>'mock_id' = ?", d.metadata, ^sample.mock_id))
      |> Repo.one()

    if existing do
      {:skip, existing}
    else
      {:ok, create_sample_document(scope, patient, record_set, sample, timestamp)}
    end
  end

  defp create_sample_document(scope, patient, record_set, sample, timestamp) do
    content = sample_content(sample)
    metadata = sample_metadata(sample, timestamp)

    upload =
      %DocumentUpload{}
      |> DocumentUpload.changeset(%{
        tenant_id: tenant_id_from_scope(scope),
        patient_id: patient.id,
        record_set_id: record_set.id,
        document_kind: sample.document_kind,
        filename: sample.filename,
        content_type: "application/pdf",
        byte_size: byte_size(content),
        sha256: sha256(content),
        status: "parsed",
        storage_backend: "fixtures",
        raw_blob: content,
        metadata: metadata,
        ingested_at: timestamp
      })
      |> Repo.insert!()

    parse =
      %DocumentParse{}
      |> DocumentParse.changeset(%{
        upload_id: upload.id,
        parser: "sample-fixture",
        parsed_text: content,
        structured_metadata: %{
          "mock_id" => sample.mock_id,
          "lines" => sample.lines,
          "provider" => sample.provider
        },
        extracted_at: timestamp,
        patient_profile_id: patient.current_profile_id
      })
      |> Repo.insert!()

    persist_sample_chunks(parse, sample.lines)

    upload
  end

  defp sample_content(sample) do
    sample.lines
    |> Enum.map(& &1.text)
    |> Enum.join("\n")
  end

  defp sample_metadata(sample, timestamp) do
    %{
      "label" => sample.label,
      "mock_id" => sample.mock_id,
      "summary" => sample.summary,
      "provider" => sample.provider,
      "date" => sample.date,
      "status" => "parsed",
      "ingestion_stage" => "completed",
      "ingestion_progress" => 100,
      "ingestion_message" => "Synthetic fixture loaded",
      "ingestion_updated_at" => timestamp
    }
  end

  defp persist_sample_chunks(parse, lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.each(fn {line, index} ->
      %DocumentChunk{}
      |> DocumentChunk.changeset(%{
        parse_id: parse.id,
        position: index,
        content: line.text,
        token_count: line.text |> String.split() |> length(),
        line_start: index,
        line_end: index
      })
      |> Repo.insert!()
    end)
  end

  defp duplicate_upload(tenant_id, record_set_id, sha) do
    DocumentUpload
    |> where([d], d.tenant_id == ^tenant_id)
    |> where([d], d.record_set_id == ^record_set_id)
    |> where([d], d.sha256 == ^sha)
    |> Repo.one()
  end

  def queue_ingestion(%DocumentUpload{} = upload, template, opts \\ []) do
    job =
      %IngestionJob{}
      |> IngestionJob.changeset(%{
        tenant_id: upload.tenant_id,
        upload_id: upload.id,
        record_set_id: upload.record_set_id,
        job_type: "pdf_ingest",
        status: "pending",
        stage: "queued",
        metadata: %{"template_id" => template.id},
        scheduled_at: DateTime.utc_now(:second)
      })
      |> Repo.insert!()

    worker = Keyword.get(opts, :worker, DoclingIngestionWorker)

    job = Repo.update!(Changeset.change(job, status: "queued"))

    {job, _event} =
      record_job_stage!(
        Map.put(job, :upload, upload),
        "queued",
        message: "Queued for ingestion",
        progress: 5,
        upload_status: "queued"
      )

    Logger.info("Queueing ingestion for upload #{upload.id}")

    case worker.new(%{"ingestion_job_id" => job.id}) |> Oban.insert() do
      {:ok, _oban_job} ->
        {:ok, job}

      {:error, reason} ->
        Logger.error("Failed to enqueue ingestion for upload #{upload.id}: #{inspect(reason)}")

        Repo.update!(
          Changeset.change(job, %{status: "failed", error: %{message: inspect(reason)}})
        )

        record_job_stage!(
          Map.put(job, :upload, upload),
          "failed",
          message: "Failed to queue ingestion: #{inspect(reason)}",
          progress: 0,
          upload_status: "failed"
        )

        {:error, reason}
    end
  end

  def record_job_stage!(%IngestionJob{} = job, stage, opts \\ []) do
    job = ensure_job_upload(job)
    message = Keyword.get(opts, :message)
    progress = Keyword.get(opts, :progress, default_progress(stage))
    payload = Keyword.get(opts, :payload, %{})
    recorded_at = Keyword.get(opts, :recorded_at, DateTime.utc_now(:second))
    upload_status = Keyword.get(opts, :upload_status, job.upload.status)

    event =
      %IngestionEvent{}
      |> IngestionEvent.changeset(%{
        event_type: stage,
        job_id: job.id,
        recorded_at: recorded_at,
        message: message,
        progress: progress,
        payload: payload
      })
      |> Repo.insert!()

    updated_job =
      job
      |> Changeset.change(%{stage: stage, progress: progress, last_message: message})
      |> Repo.update!()
      |> Map.put(:upload, job.upload)

    upload =
      update_upload_status(job.upload, upload_status, %{
        stage: stage,
        progress: progress,
        message: message,
        job_id: job.id
      })

    notify_job_progress(%{updated_job | upload: upload}, event)

    {%{updated_job | upload: upload}, event}
  end

  def fetch_upload_status(upload_id) when is_binary(upload_id) do
    upload =
      DocumentUpload
      |> Repo.get(upload_id)
      |> Repo.preload(ingestion_jobs: [:events])

    case upload do
      nil ->
        {:error, :not_found}

      upload ->
        job = latest_job(upload.ingestion_jobs)
        {:ok, %{upload: upload, job: job, latest_event: job && latest_event(job)}}
    end
  end

  def fetch_ingestion_job(job_id) when is_binary(job_id) do
    job =
      IngestionJob
      |> Repo.get(job_id)
      |> Repo.preload([:upload, :events])

    case job do
      nil -> {:error, :not_found}
      job -> {:ok, %{job: job, latest_event: latest_event(job)}}
    end
  end

  def delete_upload(%Scope{} = scope, upload_id) do
    tenant_id = tenant_id_from_scope(scope)

    upload =
      DocumentUpload
      |> where([d], d.tenant_id == ^tenant_id)
      |> Repo.get(upload_id)

    case upload do
      nil ->
        {:error, :not_found}

      upload ->
        {:ok, _} = Repo.delete(upload)
        notify_documents_changed(upload.record_set_id)
        :ok
    end
  end

  defp ensure_job_upload(job) do
    Repo.preload(job, [upload: [:patient, :record_set]], force: true)
  end

  defp default_progress("queued"), do: 5
  defp default_progress("downloading"), do: 15
  defp default_progress("docling"), do: 50
  defp default_progress("parsing"), do: 80
  defp default_progress("completed"), do: 100
  defp default_progress("failed"), do: 100
  defp default_progress(_), do: 0

  defp latest_job([]), do: nil

  defp latest_job(collection) do
    collection
    |> Enum.max_by(& &1.inserted_at, fn -> nil end)
    |> maybe_preload_events()
  end

  defp latest_event(nil), do: nil

  defp latest_event(job) do
    job.events
    |> Enum.max_by(& &1.recorded_at, fn -> nil end)
  end

  defp maybe_preload_events(nil), do: nil

  defp maybe_preload_events(job) do
    Repo.preload(job, :events)
  end

  defp tenant_id_from_scope(%Scope{tenant_id: tenant_id}), do: tenant_id

  defp sha256(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end

  defp update_upload_status(upload, status, attrs) do
    metadata =
      (upload.metadata || %{})
      |> Map.put("status", status)
      |> maybe_put("ingestion_stage", Map.get(attrs, :stage))
      |> maybe_put("ingestion_progress", Map.get(attrs, :progress))
      |> maybe_put("ingestion_message", Map.get(attrs, :message))
      |> maybe_put("ingestion_job_id", Map.get(attrs, :job_id))
      |> Map.put("ingestion_updated_at", DateTime.utc_now(:second))

    upload =
      upload
      |> Changeset.change(%{status: status, metadata: metadata})
      |> Repo.update!()

    notify_documents_changed(upload.record_set_id)
    upload
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value) when is_binary(key), do: Map.put(map, key, value)
  defp maybe_put(map, key, value) when is_atom(key), do: Map.put(map, Atom.to_string(key), value)

  defp maybe_attach_event(payload, nil), do: payload

  defp maybe_attach_event(payload, event) do
    Map.put(payload, :event, %{
      id: event.id,
      type: event.event_type,
      progress: event.progress,
      message: event.message,
      recorded_at: event.recorded_at
    })
  end

  defp topic(record_set_id), do: "#{@topic_prefix}:#{record_set_id}:documents"
  defp job_topic(job_id), do: "#{@job_topic_prefix}:#{job_id}"
end
