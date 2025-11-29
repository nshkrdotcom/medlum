defmodule Lumainus.Documents.IngestionProcessor do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Lumainus.Conversion.Service, as: ConversionService
  alias Lumainus.Documents
  alias Lumainus.Documents.{DocumentChunk, DocumentParse, DocumentUpload, IngestionJob}
  alias Lumainus.Documents.ProgressTracker
  alias Lumainus.Clinical.PatientProfile
  alias Lumainus.Repo

  require Logger

  # Default timeout for conversion (20 minutes)
  @default_timeout_ms 1_200_000

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

    Logger.info(
      "[docling_convert] Starting for job=#{job.id} upload=#{upload.id} raw_blob_size=#{if upload.raw_blob, do: byte_size(upload.raw_blob), else: "nil"}"
    )

    # Determine profile from user's backend preference
    profile = profile_from_backend(job.backend)

    # Build user map with cloud_processing_enabled derived from backend choice
    user_for_policy = build_user_for_policy(upload.uploader, profile)

    # Build v2 Service options
    service_opts = [
      filename: upload.filename,
      content_type: upload.content_type || "application/pdf",
      profile: profile,
      tenant_id: upload.tenant_id,
      user_id: upload.uploader_id,
      user: user_for_policy,
      timeout_ms: @default_timeout_ms,
      metadata: %{
        upload_id: upload.id,
        ingestion_job_id: job.id
      }
    ]

    # Submit to v2 Conversion Service
    Logger.info("[docling_convert] Submitting to ConversionService...")
    submit_result = ConversionService.submit(upload.raw_blob, service_opts)
    Logger.info("[docling_convert] Submit result: #{inspect(submit_result, limit: 200)}")

    with {:ok, conversion_job} <- submit_result do
      # Truncate to seconds for database compatibility
      timeout_at = DateTime.truncate(conversion_job.timeout_at, :second)
      {:ok, _linked} = Documents.link_docling_job(job, conversion_job.id)

      updated_upload =
        Documents.persist_docling_job_metadata(upload, conversion_job.id, profile: profile)

      job = %{job | docling_job_id: conversion_job.id, upload: updated_upload}

      backend_name = conversion_job.backend_used || profile

      {job, _event} =
        Documents.record_job_stage!(
          job,
          "docling",
          message: "Sending binary to Docling service",
          progress: 50,
          timeout_at: timeout_at,
          payload: %{
            timeout_at: DateTime.to_iso8601(timeout_at),
            docling_job_id: conversion_job.id
          },
          state: "running",
          backend: to_string(backend_name)
        )

      # Await completion via v2 Service
      case ConversionService.await(conversion_job.id,
             on_progress: fn status -> maybe_track_progress_v2(job, status) end
           ) do
        {:ok, response} -> {:ok, response, job}
        {:error, :timeout} -> {:error, :timeout, job}
        {:error, {:failed, reason}} -> {:error, {:docling_failed, reason}, job}
        {:error, reason} -> {:error, reason, job}
      end
    else
      {:error, :file_too_large} ->
        {:error, {:docling_failed, "File exceeds 100MB limit"}, job}

      {:error, :invalid_content_type} ->
        {:error, {:docling_failed, "Only PDF files are supported"}, job}

      {:error, :service_unavailable} ->
        {:error, {:docling_failed, "No conversion backends available"}, job}

      {:error, {:provisioning_timeout, message}} ->
        {:error, {:docling_failed, message}, job}

      {:error, {:cloud_unavailable, message}} ->
        {:error, {:docling_failed, "Cloud GPU unavailable: #{message}"}, job}

      {:error, reason} ->
        {:error, reason, job}
    end
  end

  # Map user backend preference to v2 processing profile
  defp profile_from_backend(backend)
       when backend in [
              :docker_gpu,
              :local_gpu,
              :native_gpu,
              :vast_ai,
              :fast,
              :cloud,
              "docker_gpu",
              "local_gpu",
              "native_gpu",
              "vast_ai",
              "fast",
              "cloud"
            ] do
    :enhanced
  end

  defp profile_from_backend(_), do: :standard

  # Build a user map for policy checking with cloud_processing_enabled
  # derived from the profile being requested. If user chose a cloud backend,
  # they have implicitly enabled cloud processing.
  defp build_user_for_policy(uploader, profile) do
    base =
      case uploader do
        %{id: _} = user ->
          %{
            id: user.id,
            subscription: Map.get(user, :subscription),
            feature_flags: Map.get(user, :feature_flags, %{})
          }

        _ ->
          %{}
      end

    # Grant cloud_processing_enabled when requesting :enhanced profile
    # This reflects the user's explicit choice to use a cloud/GPU backend
    if profile == :enhanced do
      Map.put(base, :cloud_processing_enabled, true)
    else
      base
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
    trimmed = String.trim(markdown)
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

  defp short_summary(markdown) do
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

  defp fetch_markdown(response) do
    # SSE stream puts result in "result" key, direct API returns it at top level
    result = Map.get(response, "result", response)

    case Map.get(result, "markdown") do
      nil -> ""
      value when is_binary(value) -> value
      other -> to_string(other)
    end
  end

  defp cleanse_markdown(content) do
    content
    |> String.replace(~r/<!--\s*image\s*-->/i, "")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp parsed_digest(""), do: nil

  defp parsed_digest(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp dedup_candidate?(content) do
    String.length(content) >= @duplicate_min_length
  end

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

  defp duration_ms(%{started_at: %DateTime{} = started_at}, %DateTime{} = finished_at) do
    max(DateTime.diff(finished_at, started_at, :millisecond), 0)
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
    stage_seq = Map.get(status, "stage_seq")
    last_pages_done = state[:last_pages_emitted] || 0

    pages_done =
      case Map.get(status, "pages_done") do
        value when is_integer(value) -> max(value, last_pages_done)
        value when is_float(value) -> max(trunc(value), last_pages_done)
        _ -> last_pages_done
      end

    pages_total = Map.get(status, "pages_total") || state[:last_pages_total] || 0
    event_ts = Map.get(status, "timestamp")
    worker_id = Map.get(status, "worker_id")
    device = Map.get(status, "device")
    queue_depth = Map.get(status, "queue_depth")

    # Determine which stage this event belongs to
    stage_num =
      cond do
        is_integer(stage_seq) -> stage_seq
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

    if debug_progress_log?() do
      Logger.info(
        "[docling-progress-debug] job=#{job.id} type=#{event_type || stage_name} page=#{pages_done}/#{pages_total} overall=#{overall} stage_seq=#{stage_num} worker=#{worker_id} device=#{device} queue_depth=#{queue_depth} event_ts=#{inspect(event_ts)} now_ms=#{System.system_time(:millisecond)}"
      )
    end

    # Only emit if integer percentage changed (debouncing)
    if ProgressTracker.should_emit?(state, overall, pages_done) do
      payload =
        ProgressTracker.build_progress_payload(updated_state, pages_done, pages_total)
        |> Map.merge(%{
          "worker_id" => Map.get(status, "worker_id"),
          "device" => Map.get(status, "device"),
          "stage" => stage_name,
          "stage_seq" => stage_num,
          "queue_depth" => Map.get(status, "queue_depth"),
          "pages_failed" => Map.get(status, "pages_failed")
        })

      base_message = ProgressTracker.progress_message(updated_state, pages_done, pages_total)

      worker_info =
        case {Map.get(status, "worker_id"), Map.get(status, "device")} do
          {nil, _} -> ""
          {worker_id, nil} -> " (worker #{worker_id})"
          {worker_id, device} -> " (worker #{worker_id}, #{device})"
        end

      message = base_message <> worker_info

      # Don't broadcast progress updates - they cause full workspace reloads
      # which overwrite in-memory progress. The v2 conversion events handle UI updates.
      Documents.record_job_stage!(job, "docling",
        progress: overall,
        message: message,
        payload: payload,
        upload_status: "processing",
        broadcast: false
      )

      Process.put(state_key, %{
        updated_state
        | last_emitted_progress: overall,
          last_emitted_at: System.monotonic_time(:millisecond),
          last_pages_emitted: pages_done,
          last_pages_total: pages_total
      })
    else
      Process.put(state_key, updated_state)
    end
  end

  defp maybe_track_progress(_job, _status), do: :ok

  # v2 Service progress callback - receives JobStatus struct
  defp maybe_track_progress_v2(job, %{state: state, progress: progress} = status) do
    # Convert v2 JobStatus to v1-compatible format for existing progress tracking
    v1_status = %{
      "state" => to_string(state),
      "progress" => progress,
      "pages_done" => Map.get(status, :pages_done, 0),
      "pages_total" => Map.get(status, :pages_total, 0)
    }

    maybe_track_progress(job, v1_status)
  end

  defp maybe_track_progress_v2(_job, _status), do: :ok

  defp debug_progress_log? do
    Application.get_env(:lumainus, :conversion, [])
    |> Keyword.get(:debug_progress_log, false)
  end
end
