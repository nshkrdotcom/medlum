defmodule Lumainus.Documents do
  @moduledoc """
  High-level helpers for managing document uploads and ingestion jobs.
  """

  import Ecto.Query, warn: false
  alias Ecto.Changeset
  alias Lumainus.Accounts.Scope
  alias Lumainus.Docling.Settings

  alias Lumainus.Documents.{
    DoclingIngestionWorker,
    DocumentChunk,
    DocumentParse,
    DocumentUpload,
    IngestionConfig,
    IngestionEvent,
    IngestionJob,
    SampleData
  }

  alias Lumainus.Reports
  alias Lumainus.Repo
  alias Oban
  alias Path
  alias Phoenix.PubSub
  require Logger

  @topic_prefix "record-set"
  @job_topic_prefix "ingestion-job"
  @document_summary_preview_bytes 1_000
  @document_content_preview_bytes 200_000

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

  @doc """
  Notify that a conversion job has started for an upload, allowing LiveViews to
  subscribe to conversion events immediately without waiting for a full reload.

  This is critical for progress tracking: the LiveView needs to subscribe to
  conversion job events BEFORE await() starts broadcasting progress updates.
  """
  def notify_conversion_job_started(record_set_id, upload_id, conversion_job_id)
      when is_binary(record_set_id) and is_binary(upload_id) and is_binary(conversion_job_id) do
    PubSub.broadcast(
      LumainusWeb.PubSub,
      topic(record_set_id),
      {:conversion_job_started, record_set_id, upload_id, conversion_job_id}
    )
  end

  def notify_job_progress(%IngestionJob{} = job, event \\ nil) do
    timeout_at =
      job.timeout_at ||
        job.upload
        |> Map.get(:metadata, %{})
        |> Map.get("ingestion_timeout_at")

    payload =
      %{
        job_id: job.id,
        upload_id: job.upload_id,
        record_set_id: job.record_set_id,
        status: job.status,
        state: job.state,
        stage: job.stage,
        progress: job.progress,
        last_message: job.last_message,
        last_error: job.last_error,
        started_at: job.started_at,
        finished_at: job.finished_at,
        updated_at: job.updated_at,
        timeout_at: timeout_at,
        backend: job.backend
      }
      |> maybe_attach_event(event)

    PubSub.broadcast(
      LumainusWeb.PubSub,
      job_topic(job.id),
      {:job_progress, job.record_set_id, payload}
    )
  end

  @doc """
  List document uploads for a record set without pulling large blobs or verbose metadata.

  Only lightweight metadata needed for the UI is returned. Pass `include_summary?: true`
  to include a truncated summary in the metadata payload (omitted by default).
  """
  def list_documents(%Scope{} = scope, record_set, opts \\ []) do
    include_summary? = Keyword.get(opts, :include_summary?, false)
    summary_limit = Keyword.get(opts, :summary_limit, @document_summary_preview_bytes)

    DocumentUpload
    |> where([d], d.tenant_id == ^scope.tenant_id)
    |> where([d], d.record_set_id == ^record_set.id)
    |> order_by([d], desc: d.inserted_at)
    |> select([d], struct(d, ^document_listing_fields()))
    |> select_merge([d], %{
      metadata:
        fragment(
          """
          jsonb_strip_nulls(
            jsonb_build_object(
              'label', (?->>'label'),
              'summary', ?,
              'provider', (?->>'provider'),
              'date', (?->>'date'),
              'ingestion_state', (?->>'ingestion_state'),
              'ingestion_stage', (?->>'ingestion_stage'),
              'ingestion_progress', NULLIF((?->>'ingestion_progress'), '')::double precision,
              'ingestion_message', (?->>'ingestion_message'),
              'ingestion_error', (?->>'ingestion_error'),
              'ingestion_job_id', (?->>'ingestion_job_id'),
              'ingestion_timeout_at', (?->>'ingestion_timeout_at'),
              'progress', (?->'progress'),
              'docling_backend', (?->>'docling_backend'),
              'docling_backend_status', (?->>'docling_backend_status'),
              'docling_job_id', (?->>'docling_job_id'),
              'conversion_profile', (?->>'conversion_profile'),
              'backend', coalesce(?->>'backend', ?->>'docling_backend'),
              'status', (?->>'status'),
              'mock_id', (?->>'mock_id')
            )
          )
          """,
          d.metadata,
          fragment(
            "CASE WHEN ? THEN left(coalesce(?->>'summary', ''), ?) ELSE NULL END",
            ^include_summary?,
            d.metadata,
            ^summary_limit
          ),
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata,
          d.metadata
        )
    })
    |> Repo.all()
  end

  @doc """
  Lazily load document content for modal/detail views with strict truncation.

  By default, both cleaned text and raw blobs are capped to #{@document_content_preview_bytes} bytes
  to prevent multi-MB assigns. Use `include_raw?: false` when raw payloads are not needed.
  """
  def get_document_content(document_id, opts \\ []) when is_binary(document_id) do
    cleaned_limit = Keyword.get(opts, :cleaned_limit, @document_content_preview_bytes)
    raw_limit = Keyword.get(opts, :raw_limit, @document_content_preview_bytes)
    summary_limit = Keyword.get(opts, :summary_limit, @document_summary_preview_bytes)
    include_raw? = Keyword.get(opts, :include_raw?, true)

    upload_query =
      DocumentUpload
      |> where([d], d.id == ^document_id)

    upload =
      upload_query
      |> select([d], %{
        raw_content:
          fragment(
            "CASE WHEN ? THEN substring(coalesce(?, '\\x'::bytea) for ?) ELSE NULL::bytea END",
            ^include_raw?,
            d.raw_blob,
            ^raw_limit
          ),
        raw_size:
          fragment(
            "CASE WHEN ? THEN octet_length(coalesce(?, '\\x'::bytea)) ELSE 0::int END",
            ^include_raw?,
            d.raw_blob
          ),
        summary: fragment("left(coalesce(?->>'summary', ''), ?)", d.metadata, ^summary_limit),
        summary_size: fragment("octet_length(coalesce(?->>'summary', ''))", d.metadata)
      })
      |> Repo.one()

    parse =
      DocumentParse
      |> where([p], p.upload_id == ^document_id)
      |> order_by([p], desc: p.extracted_at)
      |> limit(1)
      |> select([p], %{
        cleaned_content:
          fragment("substring(coalesce(?, '') for ?)", p.parsed_text, ^cleaned_limit),
        cleaned_size: fragment("octet_length(coalesce(?, ''))", p.parsed_text)
      })
      |> Repo.one()

    %{
      cleaned_content: parse && parse.cleaned_content,
      cleaned_truncated?: parse && parse.cleaned_size > cleaned_limit,
      cleaned_limit: cleaned_limit,
      raw_content: upload && upload.raw_content,
      raw_truncated?: include_raw? && upload && upload.raw_size > raw_limit,
      raw_limit: if(include_raw?, do: raw_limit, else: nil),
      summary: upload && upload.summary,
      summary_truncated?: upload && upload.summary_size > summary_limit,
      summary_limit: summary_limit
    }
  end

  defp document_listing_fields do
    DocumentUpload.__schema__(:fields)
    |> Enum.reject(&(&1 == :raw_blob))
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
    %DocumentUpload{}
    |> DocumentUpload.changeset(attrs)
    |> Repo.insert()
  end

  defp ensure_sample_document(scope, patient, record_set, sample, timestamp) do
    existing =
      DocumentUpload
      |> where([d], d.record_set_id == ^record_set.id)
      |> where([d], fragment("?->>'mock_id' = ?", d.metadata, ^sample.mock_id))
      |> Repo.one()

    cond do
      existing ->
        {:skip, existing}

      true ->
        {:ok, create_sample_document(scope, patient, record_set, sample, timestamp)}
    end
  end

  defp create_sample_document(scope, patient, record_set, sample, timestamp) do
    content = sample_content(sample)
    metadata = sample_metadata(sample, timestamp)

    # For synthetic fixtures, include the record_set_id in the digest so we can
    # safely seed the same sample documents into multiple workspaces without
    # tripping the tenant-wide sha256 uniqueness constraint.
    digest = sha256(content <> record_set.id)

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
        sha256: digest,
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

  def queue_ingestion(%DocumentUpload{} = upload, template, opts \\ []) do
    requested_backend = Keyword.get(opts, :backend)

    # Guard: Check for existing active ingestion job for this upload
    case find_active_ingestion_job(upload.id) do
      nil ->
        do_queue_ingestion(upload, template, opts, requested_backend)

      existing_job ->
        Logger.warning(
          "[queue_ingestion] BLOCKED duplicate ingestion: upload_id=#{upload.id} " <>
            "filename=#{upload.filename} existing_job_id=#{existing_job.id} " <>
            "existing_state=#{existing_job.state} existing_stage=#{existing_job.stage}"
        )

        {:error, :already_queued}
    end
  end

  defp do_queue_ingestion(upload, template, opts, requested_backend) do
    case resolve_docling_backend(opts) do
      {:error, :cloud_unavailable, reason} ->
        Logger.warning(
          "[queue_ingestion] BLOCKED cloud unavailable: upload_id=#{upload.id} " <>
            "filename=#{upload.filename} reason=#{inspect(reason)}"
        )

        {:error, :cloud_unavailable, reason}

      {:ok, backend, backend_reason} ->
        do_queue_ingestion_with_backend(
          upload,
          template,
          opts,
          requested_backend,
          backend,
          backend_reason
        )
    end
  end

  defp do_queue_ingestion_with_backend(
         upload,
         template,
         opts,
         requested_backend,
         backend,
         backend_reason
       ) do
    backend_string = Atom.to_string(backend)
    max_attempts = IngestionConfig.max_retries()
    deadline = IngestionConfig.calculate_deadline(max_retries: max_attempts)
    upload = persist_backend_choice(upload, backend_string, backend_reason)

    job =
      %IngestionJob{}
      |> IngestionJob.changeset(%{
        tenant_id: upload.tenant_id,
        upload_id: upload.id,
        record_set_id: upload.record_set_id,
        job_type: "pdf_ingest",
        status: "queued",
        state: "queued",
        stage: "queued",
        max_attempts: max_attempts,
        deadline_at: deadline,
        metadata: backend_metadata(template, backend_string, backend_reason, opts),
        backend: backend_string,
        scheduled_at: DateTime.utc_now(:second)
      })
      |> Repo.insert!()

    worker = Keyword.get(opts, :worker, DoclingIngestionWorker)

    job = Repo.update!(Changeset.change(job, %{status: "queued", state: "queued"}))

    {job, _event} =
      record_job_stage!(
        Map.put(job, :upload, upload),
        "queued",
        message: "Queued for ingestion",
        progress: 5,
        upload_status: "queued",
        backend: backend_string,
        payload: %{
          backend: backend_string,
          backend_status: backend_status(backend_reason)
        }
      )

    case worker.new(%{"ingestion_job_id" => job.id}) |> Oban.insert() do
      {:ok, oban_job} ->
        # Link Oban job ID for cancellation support
        {:ok, job} = link_oban_job(job, oban_job.id)

        Logger.info(
          "[queue_ingestion] SUCCESS upload_id=#{upload.id} filename=#{upload.filename} " <>
            "job_id=#{job.id} oban_job_id=#{oban_job.id} backend=#{backend_string} " <>
            "requested_backend=#{inspect(requested_backend)} " <>
            "backend_reason=#{inspect(backend_reason)} deadline=#{deadline}"
        )

        {:ok, job}

      {:error, reason} ->
        Logger.error(
          "[queue_ingestion] FAILED upload_id=#{upload.id} filename=#{upload.filename} " <>
            "job_id=#{job.id} error=#{inspect(reason)}"
        )

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

  @doc """
  Finds an active (queued or running) ingestion job for the given upload.
  Returns nil if no active job exists.
  """
  def find_active_ingestion_job(upload_id) when is_binary(upload_id) do
    IngestionJob
    |> where([j], j.upload_id == ^upload_id)
    |> where([j], j.state in ["queued", "running"])
    |> where([j], is_nil(j.cancelled_at))
    |> order_by([j], desc: j.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def retry_ingestion(upload_id, opts \\ [])

  def retry_ingestion(upload_id, opts) when is_binary(upload_id) do
    case Repo.get(DocumentUpload, upload_id) do
      nil ->
        {:error, :not_found}

      upload ->
        upload = Repo.preload(upload, [:patient, :record_set])

        with {:ok, template} <- resolve_retry_template(opts) do
          queue_ingestion(upload, template, opts)
        end
    end
  end

  defp resolve_retry_template(opts) do
    cond do
      Keyword.get(opts, :template) ->
        {:ok, Keyword.get(opts, :template)}

      Keyword.get(opts, :template_id) ->
        {:ok, Reports.get_template!(Keyword.fetch!(opts, :template_id))}

      true ->
        {:error, :template_required}
    end
  rescue
    _ -> {:error, :template_invalid}
  end

  def record_job_stage!(%IngestionJob{} = job, stage, opts \\ []) do
    job = ensure_job_upload(job)
    message = Keyword.get(opts, :message)
    progress = Keyword.get(opts, :progress, default_progress(stage))
    payload = Keyword.get(opts, :payload, %{})
    recorded_at = Keyword.get(opts, :recorded_at, DateTime.utc_now(:second))
    upload_status = Keyword.get(opts, :upload_status, job.upload.status)
    timeout_at = Keyword.get(opts, :timeout_at)
    state = Keyword.get(opts, :state, state_for_stage(stage))
    last_error = Keyword.get(opts, :last_error)
    broadcast? = Keyword.get(opts, :broadcast, true)

    backend_value =
      Keyword.get(opts, :backend, job.backend) |> maybe_backend_string() || job.backend

    event_payload =
      payload
      |> maybe_put_datetime(:timeout_at, timeout_at)
      |> maybe_put(:state, state)
      |> maybe_put(:last_error, last_error_for_stage(stage, last_error))
      |> maybe_put(:backend, backend_value)

    event =
      %IngestionEvent{}
      |> IngestionEvent.changeset(%{
        event_type: stage,
        job_id: job.id,
        recorded_at: recorded_at,
        message: message,
        progress: progress,
        payload: event_payload
      })
      |> Repo.insert!()

    job_changes =
      %{
        stage: stage,
        progress: progress,
        last_message: message,
        state: state,
        last_error: last_error_for_stage(stage, last_error),
        backend: backend_value
      }
      |> put_optional(:timeout_at, timeout_at)

    updated_job =
      job
      |> Changeset.change(job_changes)
      |> Repo.update!()
      |> Map.put(:upload, job.upload)

    upload =
      update_upload_status(
        job.upload,
        upload_status,
        %{
          stage: stage,
          progress: progress,
          message: message,
          job_id: job.id,
          state: state,
          error_message: last_error_for_stage(stage, last_error),
          timeout_at: timeout_at,
          payload: event_payload,
          backend: backend_value
        },
        broadcast: broadcast?
      )

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
    case job.upload do
      %DocumentUpload{} = upload ->
        refreshed =
          upload
          |> Repo.reload!()
          |> Repo.preload([:patient, :record_set])

        %{job | upload: refreshed}

      _ ->
        # Not loaded at all, do full preload
        Repo.preload(job, upload: [:patient, :record_set])
    end
  end

  defp default_progress("queued"), do: 5
  defp default_progress("downloading"), do: 15
  defp default_progress("docling"), do: 50
  defp default_progress("parsing"), do: 80
  defp default_progress("completed"), do: 100
  defp default_progress("failed"), do: 100
  defp default_progress(_), do: 0

  defp state_for_stage("queued"), do: "queued"

  defp state_for_stage(stage) when stage in ["downloading", "docling", "parsing"],
    do: "running"

  defp state_for_stage("completed"), do: "completed"
  defp state_for_stage("failed"), do: "failed"
  defp state_for_stage(_), do: "pending"

  defp last_error_for_stage("failed", nil), do: "Ingestion failed"
  defp last_error_for_stage("failed", error), do: to_string(error)
  defp last_error_for_stage(_stage, _error), do: nil

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

  # =============================================================================
  # Job Lifecycle Management
  # =============================================================================

  @doc """
  Marks a job as processing and records the attempt.
  """
  def mark_job_processing(%IngestionJob{} = job, attempt_number) do
    timeout_ms = IngestionConfig.conversion_timeout_ms()
    now = DateTime.utc_now(:second)
    timeout_at = now |> DateTime.add(div(timeout_ms, 1000), :second)

    job
    |> Changeset.change(%{
      state: "running",
      stage: "downloading",
      status: "processing",
      attempt_number: attempt_number,
      attempts: (job.attempts || 0) + 1,
      started_at: now,
      timeout_at: timeout_at,
      last_error: nil
    })
    |> Repo.update()
  end

  @doc """
  Marks a job as completed successfully.
  """
  def mark_job_completed(%IngestionJob{} = job) do
    job
    |> Changeset.change(%{
      state: "completed",
      status: "completed",
      finished_at: DateTime.utc_now(:second),
      last_error: nil
    })
    |> Repo.update()
  end

  @doc """
  Marks a job as failed with an error message.
  """
  def mark_job_failed(%IngestionJob{} = job, error_message) do
    job
    |> Changeset.change(%{
      state: "failed",
      status: "failed",
      finished_at: DateTime.utc_now(:second),
      last_error: error_message
    })
    |> Repo.update()
  end

  @doc """
  Records an error in the job's error history.
  """
  def record_job_error(%IngestionJob{} = job, attempt, reason) do
    error_entry = %{
      "attempt" => attempt,
      "reason" => inspect(reason),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    job
    |> Changeset.change(%{
      error_history: (job.error_history || []) ++ [error_entry],
      last_error: inspect(reason)
    })
    |> Repo.update()
  end

  @doc """
  Cancels an ingestion job.
  """
  def cancel_ingestion_job(job_id) when is_binary(job_id) do
    job = Repo.get!(IngestionJob, job_id)

    cond do
      job.cancelled_at != nil ->
        {:error, :already_cancelled}

      job.state == "completed" ->
        {:error, :already_completed}

      true ->
        job
        |> Changeset.change(%{
          cancelled_at: DateTime.utc_now(:second),
          state: "failed",
          status: "failed",
          last_error: "Cancelled by user",
          finished_at: DateTime.utc_now(:second)
        })
        |> Repo.update!()

        # Cancel Oban job if linked
        if job.oban_job_id do
          Oban.cancel_job(job.oban_job_id)
        end

        :ok
    end
  end

  @doc """
  Checks if a job should be retried.
  """
  def should_retry?(%IngestionJob{} = job) do
    cond do
      job.cancelled_at != nil ->
        false

      job.deadline_at && DateTime.compare(DateTime.utc_now(), job.deadline_at) == :gt ->
        false

      job.attempt_number >= job.max_attempts ->
        false

      true ->
        true
    end
  end

  @doc """
  Sets the hard deadline for a job based on configuration.
  """
  def set_deadline(%IngestionJob{} = job, _opts \\ []) do
    deadline =
      IngestionConfig.calculate_deadline(
        timeout_ms: IngestionConfig.conversion_timeout_ms(),
        max_retries: job.max_attempts
      )

    job
    |> Changeset.change(%{deadline_at: deadline})
    |> Repo.update()
  end

  @doc """
  Links an Oban job ID to the ingestion job.
  """
  def link_oban_job(%IngestionJob{} = job, oban_job_id) do
    job
    |> Changeset.change(%{oban_job_id: oban_job_id})
    |> Repo.update()
  end

  @doc """
  Links a Docling job ID to the ingestion job.
  """
  def link_docling_job(%IngestionJob{} = job, docling_job_id) do
    job
    |> Changeset.change(%{docling_job_id: docling_job_id})
    |> Repo.update()
  end

  @doc """
  Persist the Docling v2 job identifier (and optional profile) on the upload metadata.

  Stores the `docling_job_id` so downstream consumers (e.g., LiveViews) can
  correlate v2 Conversion events with documents. Optionally records the
  `conversion_profile` (as a string) for provenance.
  """
  def persist_docling_job_metadata(%DocumentUpload{} = upload, docling_job_id, opts \\ []) do
    profile = Keyword.get(opts, :profile)
    status = upload.status || "pending"

    attrs = %{
      docling_job_id: docling_job_id,
      conversion_profile: profile && Atom.to_string(profile)
    }

    # Broadcast conversion job started event FIRST so LiveViews can subscribe
    # before the ConversionService.await() starts broadcasting progress events.
    # This is critical because load_workspace takes 2-3 seconds and progress
    # events would be missed during that time.
    notify_conversion_job_started(upload.record_set_id, upload.id, docling_job_id)

    update_upload_status(upload, status, attrs, broadcast: true)
  end

  @doc """
  Archives a completed or failed job.
  """
  def archive_job(%IngestionJob{} = job) do
    if job.state in ["completed", "failed"] do
      job
      |> Changeset.change(%{archived_at: DateTime.utc_now(:second)})
      |> Repo.update()
    else
      {:error, :not_terminal}
    end
  end

  @doc """
  Finds jobs that are stuck in processing state.
  """
  def find_stale_jobs do
    threshold = IngestionConfig.stale_job_threshold_minutes()
    cutoff = DateTime.add(DateTime.utc_now(), -threshold, :minute)

    IngestionJob
    |> where([j], j.state == "running")
    |> where([j], is_nil(j.archived_at))
    |> where([j], j.updated_at < ^cutoff)
    |> Repo.all()
  end

  @doc """
  Finds jobs ready for archival.
  """
  def find_jobs_for_archival do
    days = IngestionConfig.archive_after_days()
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    IngestionJob
    |> where([j], j.state in ["completed", "failed"])
    |> where([j], is_nil(j.archived_at))
    |> where([j], j.finished_at < ^cutoff)
    |> Repo.all()
  end

  @doc """
  Basic usage summary for fast (GPU) Docling jobs grouped by day.
  """
  def fast_usage_summary(opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7, :day))

    IngestionJob
    |> where([j], j.backend == "fast")
    |> where([j], j.inserted_at >= ^since)
    |> group_by([j], fragment("date(?)", j.inserted_at))
    |> select([j], %{
      date: fragment("date(?)", j.inserted_at),
      jobs: count(j.id),
      pages: fragment("COALESCE(sum((metadata->>'pages_total')::int), 0)"),
      duration_ms: fragment("COALESCE(sum((metadata->>'duration_ms')::bigint), 0)")
    })
    |> Repo.all()
  end

  defp resolve_docling_backend(opts) do
    raw_requested = Keyword.get(opts, :backend)
    default_backend = user_backend_default()

    requested =
      (raw_requested || default_backend)
      |> normalize_user_backend()

    # Use InstanceManager state instead of HTTP health check
    # This is INSTANT - no HTTP calls, no delays
    # InstanceManager maintains health state via periodic background checks
    case requested do
      :cloud ->
        cloud_status = Lumainus.Conversion.CloudStatus.get()

        if cloud_status.can_accept_jobs do
          Logger.info(
            "[resolve_docling_backend] requested=#{inspect(raw_requested)} normalized=:cloud " <>
              "default=#{default_backend} availability=#{cloud_status.availability} " <>
              "detail=#{inspect(cloud_status.detail)}"
          )

          {:ok, :cloud, nil}
        else
          reason = cloud_status.detail || cloud_status.message || "Cloud GPU unavailable"

          Logger.warning(
            "[resolve_docling_backend] REJECTED requested=#{inspect(raw_requested)} " <>
              "normalized=:cloud default=#{default_backend} availability=#{cloud_status.availability} " <>
              "reason=#{inspect(reason)}"
          )

          {:error, :cloud_unavailable, reason}
        end

      other ->
        Logger.info(
          "[resolve_docling_backend] requested=#{inspect(raw_requested)} " <>
            "normalized=#{other} default=#{default_backend} " <>
            "gpu_check=SKIPPED final_backend=#{other}"
        )

        {:ok, other, nil}
    end
  end

  defp persist_backend_choice(upload, backend_string, backend_reason) do
    metadata =
      (upload.metadata || %{})
      |> Map.put("docling_backend", backend_string)
      |> maybe_put("docling_backend_status", backend_status(backend_reason))

    upload
    |> Changeset.change(%{metadata: metadata})
    |> Repo.update!()
  end

  defp backend_metadata(template, backend_string, backend_reason, opts) do
    requested_backend =
      opts
      |> Keyword.get(:backend)
      |> maybe_backend_string()

    %{"template_id" => template.id, "backend" => backend_string}
    |> maybe_put("requested_backend", requested_backend)
    |> maybe_put("backend_fallback_reason", format_backend_reason(backend_reason))
  end

  defp maybe_backend_string(nil), do: nil

  defp maybe_backend_string(backend) do
    backend
    |> normalize_user_backend()
    |> Atom.to_string()
  rescue
    _ -> nil
  end

  defp backend_status(_reason), do: "available"

  defp format_backend_reason(_reason), do: nil

  defp sha256(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end

  defp update_upload_status(upload, status, attrs, opts) do
    broadcast? = Keyword.get(opts, :broadcast, true)

    metadata =
      (upload.metadata || %{})
      |> Map.put("status", status)
      |> maybe_put("docling_backend", Map.get(attrs, :backend) || Map.get(attrs, "backend"))
      |> maybe_put(
        "docling_job_id",
        Map.get(attrs, :docling_job_id) || Map.get(attrs, "docling_job_id")
      )
      |> maybe_put(
        "conversion_profile",
        Map.get(attrs, :conversion_profile) || Map.get(attrs, "conversion_profile")
      )
      |> maybe_put("ingestion_state", Map.get(attrs, :state))
      |> maybe_put("ingestion_stage", Map.get(attrs, :stage))
      |> maybe_put("ingestion_progress", Map.get(attrs, :progress))
      |> maybe_put("ingestion_message", Map.get(attrs, :message))
      |> maybe_put("ingestion_job_id", Map.get(attrs, :job_id))
      |> maybe_put_datetime("ingestion_timeout_at", Map.get(attrs, :timeout_at))
      |> maybe_put_or_drop("ingestion_error", Map.get(attrs, :error_message))
      |> maybe_put_progress_payload(Map.get(attrs, :payload))
      |> Map.put("ingestion_updated_at", DateTime.utc_now(:second))

    upload =
      upload
      |> Changeset.change(%{status: status, metadata: metadata})
      |> Repo.update!()

    if broadcast? do
      notify_documents_changed(upload.record_set_id)
    end

    upload
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value) when is_binary(key), do: Map.put(map, key, value)
  defp maybe_put(map, key, value) when is_atom(key), do: Map.put(map, Atom.to_string(key), value)

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value) when is_atom(key), do: Map.put(map, key, value)

  defp maybe_put_or_drop(map, key, nil), do: Map.delete(map, to_string(key))

  defp maybe_put_or_drop(map, key, value), do: Map.put(map, to_string(key), value)

  defp maybe_put_progress_payload(map, nil), do: map

  defp maybe_put_progress_payload(map, payload) when is_map(payload) do
    # Convert atom keys to string keys for JSON storage
    progress =
      Enum.into(payload, %{}, fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)

    Map.put(map, "progress", progress)
  end

  defp maybe_put_progress_payload(map, _), do: map

  defp maybe_put_datetime(map, _key, nil), do: map

  defp maybe_put_datetime(map, key, %DateTime{} = dt) do
    maybe_put(map, key, DateTime.to_iso8601(dt))
  end

  defp maybe_put_datetime(map, key, value), do: maybe_put(map, key, value)

  defp maybe_attach_event(payload, nil), do: payload

  defp maybe_attach_event(payload, event) do
    Map.put(payload, :event, %{
      id: event.id,
      type: event.event_type,
      progress: event.progress,
      message: event.message,
      recorded_at: event.recorded_at,
      payload: event.payload
    })
  end

  defp topic(record_set_id), do: "#{@topic_prefix}:#{record_set_id}:documents"
  defp job_topic(job_id), do: "#{@job_topic_prefix}:#{job_id}"

  # User backend preference helpers (replacing v1 Docling functions)
  defp user_backend_default do
    {:ok, settings} = Settings.fetch_or_init()

    case settings.default_mode do
      "cloud" -> :cloud
      _ -> :local
    end
  end

  defp normalize_user_backend(nil), do: :local
  defp normalize_user_backend(:local), do: :local
  defp normalize_user_backend("local"), do: :local
  defp normalize_user_backend(:cloud), do: :cloud
  defp normalize_user_backend("cloud"), do: :cloud
  defp normalize_user_backend(:fast), do: :cloud
  defp normalize_user_backend("fast"), do: :cloud
  defp normalize_user_backend(_), do: :local
end
