defmodule Lumainus.Documents do
  @moduledoc """
  High-level helpers for managing document uploads and ingestion jobs.
  """

  import Ecto.Query, warn: false
  alias Ecto.Changeset
  alias Lumainus.Accounts.Scope
  alias Lumainus.Documents.{DoclingIngestionWorker, DocumentUpload, IngestionEvent, IngestionJob}
  alias Lumainus.Repo
  alias Oban
  alias Path
  alias Phoenix.PubSub

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

    case %DocumentUpload{}
         |> DocumentUpload.changeset(attrs)
         |> Repo.insert() do
      {:ok, upload} = result ->
        notify_documents_changed(upload.record_set_id)
        result

      error ->
        error
    end
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

    case worker.new(%{"ingestion_job_id" => job.id}) |> Oban.insert() do
      {:ok, _oban_job} ->
        {:ok, job}

      {:error, reason} ->
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
