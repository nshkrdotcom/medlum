defmodule Lumainus.Documents.IngestionProcessor do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Lumainus.Docling
  alias Lumainus.Documents
  alias Lumainus.Documents.{DocumentChunk, DocumentParse, DocumentUpload, IngestionJob}
  alias Lumainus.Documents.ProgressTracker
  alias Lumainus.Clinical.PatientProfile
  alias Lumainus.Repo

  require Logger

  @duplicate_min_length 8

  def process(job_id) do
    job =
      IngestionJob
      |> Repo.get!(job_id)
      |> Repo.preload(upload: [:patient, :record_set, :uploader])

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
      |> Changeset.change(%{
        status: "processing",
        state: "running",
        started_at: DateTime.utc_now(:second)
      })
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
    upload = job.upload

    backend =
      try do
        job.backend |> Docling.normalize_user_backend()
      rescue
        _ -> Docling.user_backend_default()
      end

    docling_opts =
      [
        filename: upload.filename,
        content_type: upload.content_type,
        byte_size: upload.byte_size,
        upload_id: upload.id,
        job_id: job.id,
        timeout_ms: Docling.timeout(),
        backend: backend
      ]

    with {:ok, queue_job} <- Docling.enqueue(upload.raw_blob, docling_opts) do
      timeout_at = queue_job.timeout_at
      {:ok, _linked} = Documents.link_docling_job(job, queue_job.job_id)
      job = %{job | docling_job_id: queue_job.job_id}

      {job, _event} =
        Documents.record_job_stage!(
          job,
          "docling",
          message: "Sending binary to Docling service",
          progress: 50,
          timeout_at: timeout_at,
          payload: %{timeout_at: timeout_at, docling_job_id: queue_job.job_id},
          state: "running",
          backend: Atom.to_string(backend)
        )

      case Docling.await(queue_job,
             on_status: fn status -> maybe_track_progress(job, status) end
           ) do
        {:ok, response} -> {:ok, response, job}
        {:error, reason} -> {:error, reason, job}
      end
    else
      {:error, reason} ->
        {:error, reason, job}
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

    markdown = response |> fetch_markdown() |> cleanse_markdown()
    trimmed = String.trim(markdown || "")
    digest = parsed_digest(trimmed)
    dedup_target = dedup_candidate?(trimmed)
    duplicate_of = dedup_target && find_duplicate_parse(upload.tenant_id, digest)

    metadata =
      (response["metadata"] || %{})
      |> Map.put("parsed_digest", digest)
      |> maybe_put_duplicate(duplicate_of)

    parse =
      %DocumentParse{}
      |> DocumentParse.changeset(%{
        upload_id: upload.id,
        parser: "docling",
        parsed_text: markdown,
        structured_metadata: Map.put(response, "parsed_digest", digest),
        extracted_at: DateTime.utc_now(:second),
        patient_profile_id: upload.patient && upload.patient.current_profile_id
      })
      |> Repo.insert!()

    persist_chunks(parse, markdown)

    maybe_update_patient(upload, response)

    updated_upload =
      refresh_upload_metadata(upload, markdown, metadata,
        duplicate_of: duplicate_of,
        dedup_target?: dedup_target
      )

    {:ok, parse, %{job | upload: updated_upload}}
  end

  defp refresh_upload_metadata(upload, markdown, docling_metadata, opts) do
    summary = short_summary(markdown)
    duplicate_of = Keyword.get(opts, :duplicate_of)
    dedup_target? = Keyword.get(opts, :dedup_target?, false)

    updated_metadata =
      (upload.metadata || %{})
      |> Map.put("summary", summary)
      |> Map.put("status", "parsed")
      |> Map.put("ingestion_stage", "completed")
      |> Map.put("ingestion_progress", 100)
      |> Map.put("ingestion_message", dedup_message(duplicate_of, dedup_target?))
      |> maybe_put_duplicate_metadata(duplicate_of)
      |> Map.put("page_count", docling_metadata["page_count"])
      |> Map.put("source_kind", docling_metadata["source_kind"])
      |> Map.put("has_tables", docling_metadata["has_tables"])
      |> Map.put("parsed_digest", docling_metadata["parsed_digest"])

    updated_upload =
      upload
      |> Changeset.change(%{
        status: "parsed",
        metadata: updated_metadata,
        ingested_at: DateTime.utc_now(:second)
      })
      |> Repo.update!()

    Documents.notify_documents_changed(upload.record_set_id)
    updated_upload
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
    finished_at = DateTime.utc_now(:second)
    metrics = job_metrics(job, finished_at)

    job =
      job
      |> Changeset.change(%{
        status: "completed",
        state: "completed",
        finished_at: finished_at,
        last_error: nil,
        metadata: merge_metrics(job.metadata || %{}, metrics)
      })
      |> Repo.update!()
      |> Map.put(:upload, job.upload)

    log_job_cost(job, metrics, "completed")

    Documents.record_job_stage!(
      job,
      "completed",
      message: "Docling ingestion finished",
      progress: 100
    )
  end

  defp finalize_job(job, {:error, reason}) do
    error_message = friendly_error(reason)
    finished_at = DateTime.utc_now(:second)
    metrics = job_metrics(job, finished_at)

    job =
      job
      |> Changeset.change(%{
        status: "failed",
        state: "failed",
        finished_at: finished_at,
        error: %{message: inspect(reason)},
        last_error: error_message,
        metadata: merge_metrics(job.metadata || %{}, metrics)
      })
      |> Repo.update!()
      |> Map.put(:upload, job.upload)

    log_job_cost(job, metrics, "failed")

    Documents.record_job_stage!(
      job,
      "failed",
      message: "Docling ingestion failed: #{error_message}",
      upload_status: "failed",
      last_error: error_message
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

  defp parsed_digest(""), do: nil
  defp parsed_digest(nil), do: nil

  defp parsed_digest(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp dedup_candidate?(content) when is_binary(content) do
    String.length(content) >= @duplicate_min_length
  end

  defp dedup_candidate?(_), do: false

  defp find_duplicate_parse(_tenant_id, nil), do: nil

  defp find_duplicate_parse(tenant_id, digest) do
    DocumentParse
    |> join(:inner, [p], u in DocumentUpload, on: u.id == p.upload_id)
    |> where([p, u], u.tenant_id == ^tenant_id)
    |> where([p], fragment("?->>'parsed_digest' = ?", p.structured_metadata, ^digest))
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      parse -> Repo.preload(parse, :upload)
    end
  end

  defp maybe_put_duplicate(metadata, nil), do: metadata
  defp maybe_put_duplicate(metadata, duplicate) when duplicate in [false, true], do: metadata

  defp maybe_put_duplicate(metadata, %{upload: upload}) do
    metadata
    |> Map.put("duplicate_of_upload_id", upload.id)
    |> Map.put("duplicate_of_filename", upload.filename)
  end

  defp dedup_message(nil, _), do: "Docling ingestion finished"

  defp dedup_message(%{upload: upload}, true) do
    "Duplicate content detected; matches #{upload.filename}"
  end

  defp dedup_message(_duplicate_of, _), do: "Docling ingestion finished"

  defp maybe_put_duplicate_metadata(metadata, nil), do: metadata

  defp maybe_put_duplicate_metadata(metadata, duplicate) when duplicate in [false, true],
    do: metadata

  defp maybe_put_duplicate_metadata(metadata, %{upload: upload}) do
    metadata
    |> Map.put("duplicate_of_upload_id", upload.id)
    |> Map.put("duplicate_of_filename", upload.filename)
  end

  defp friendly_error({:docling_failed, nil}), do: "Docling ingestion failed"
  defp friendly_error({:docling_failed, message}) when is_binary(message), do: message

  defp friendly_error({:http_error, status, body}) do
    "Docling returned #{status}: #{inspect(body)}"
  end

  defp friendly_error(:timeout), do: "Docling queue did not return before the timeout"
  defp friendly_error({:timeout, _}), do: "Docling queue did not return before the timeout"
  defp friendly_error(reason) when is_binary(reason), do: reason
  defp friendly_error(reason), do: inspect(reason)

  defp job_metrics(job, finished_at) do
    %{
      "backend" => job.backend || "local",
      "duration_ms" => duration_ms(job, finished_at),
      "pages_total" => pages_total(job)
    }
  end

  defp duration_ms(%{started_at: %DateTime{} = started_at}, finished_at) do
    end_time = finished_at || DateTime.utc_now(:second)
    max(DateTime.diff(end_time, started_at, :millisecond), 0)
  end

  defp duration_ms(_job, _finished_at), do: nil

  defp pages_total(job) do
    upload_metadata = (job.upload && job.upload.metadata) || %{}

    get_in(upload_metadata, ["progress", "pages_total"]) ||
      upload_metadata["page_count"] ||
      (job.metadata || %{})["pages_total"]
  end

  defp merge_metrics(metadata, metrics) do
    Enum.reduce(metrics, metadata, fn
      {_k, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp log_job_cost(job, metrics, status) do
    Logger.info(
      "DOCLOG backend=#{metrics["backend"]} pages=#{metrics["pages_total"] || 0} duration_ms=#{metrics["duration_ms"] || 0} user_id=#{job.upload && job.upload.uploader_id} job_id=#{job.id} upload_id=#{job.upload_id} status=#{status}"
    )
  end

  defp maybe_track_progress(job, %{"state" => "running"} = status) do
    state_key = {:docling_progress_state, job.id}
    state = Process.get(state_key, ProgressTracker.initial_state())

    event_type = Map.get(status, "type")
    stage_name = Map.get(status, "stage")
    pages_done = Map.get(status, "pages_done") || 0
    pages_total = Map.get(status, "pages_total") || 1

    # Determine which stage this event belongs to
    stage_num =
      cond do
        stage_name -> ProgressTracker.docling_stage_to_number(stage_name)
        event_type -> ProgressTracker.event_type_to_stage(event_type) || 2
        true -> 2
      end

    # Calculate stage internal progress based on pages
    stage_internal =
      if pages_total > 0 do
        trunc(pages_done / pages_total * 100)
      else
        0
      end

    # Update stage progress
    updated_state = ProgressTracker.update_stage(state, stage_num, stage_internal)

    # Calculate overall progress
    stage_progress_map = Enum.into(updated_state.stages, %{}, fn {k, v} -> {k, v.progress} end)
    overall = ProgressTracker.calculate_overall(stage_progress_map)

    # Only emit if integer percentage changed (debouncing)
    if ProgressTracker.should_emit?(state.last_emitted_progress, overall) do
      payload = ProgressTracker.build_progress_payload(updated_state, pages_done, pages_total)
      message = ProgressTracker.progress_message(updated_state, pages_done, pages_total)

      Documents.record_job_stage!(job, "docling",
        progress: overall,
        message: message,
        payload: payload,
        upload_status: "processing",
        broadcast: true
      )

      Process.put(state_key, %{updated_state | last_emitted_progress: overall})
    else
      Process.put(state_key, updated_state)
    end
  end

  defp maybe_track_progress(_job, _status), do: :ok
end
