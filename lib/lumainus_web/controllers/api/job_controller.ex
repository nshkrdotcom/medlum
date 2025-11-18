defmodule LumainusWeb.Api.JobController do
  use LumainusWeb, :controller

  alias Lumainus.Documents

  action_fallback LumainusWeb.ApiFallbackController

  def status(conn, %{"id" => job_id}) do
    with {:ok, %{job: job, latest_event: event}} <- Documents.fetch_ingestion_job(job_id) do
      json(conn, %{
        job: job_payload(job),
        upload: upload_payload(job.upload),
        latest_event: event_payload(event)
      })
    end
  end

  def stream(conn, %{"id" => job_id} = params) do
    once? = Map.get(params, "once") in ["1", "true"]

    with {:ok, %{job: job}} <- Documents.fetch_ingestion_job(job_id) do
      Documents.subscribe_to_ingestion_job(job_id)

      conn =
        conn
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("x-accel-buffering", "no")
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      {:ok, conn} = chunk(conn, encode_sse("progress", payload_for(job)))

      cond do
        once? -> conn
        job.stage in ["completed", "failed"] -> conn
        true -> stream_loop(conn)
      end
    end
  end

  defp stream_loop(conn) do
    receive do
      {:job_progress, _record_set_id, payload} ->
        case chunk(conn, encode_sse("progress", payload)) do
          {:ok, conn} ->
            if terminal_stage?(payload) do
              conn
            else
              stream_loop(conn)
            end

          {:error, :closed} ->
            conn
        end
    after
      30_000 ->
        case chunk(conn, "event: ping\ndata: {}\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  defp terminal_stage?(payload) do
    stage = Map.get(payload, :stage) || Map.get(payload, "stage")
    stage in ["completed", "failed"]
  end

  defp job_payload(nil), do: nil

  defp job_payload(job) do
    %{
      id: job.id,
      status: job.status,
      stage: job.stage,
      progress: job.progress,
      last_message: job.last_message,
      started_at: job.started_at,
      finished_at: job.finished_at,
      inserted_at: job.inserted_at,
      updated_at: job.updated_at,
      events: Enum.map(job.events || [], &event_payload/1)
    }
  end

  defp upload_payload(nil), do: nil

  defp upload_payload(upload) do
    %{
      id: upload.id,
      record_set_id: upload.record_set_id,
      status: upload.status,
      filename: upload.filename,
      metadata: upload.metadata
    }
  end

  defp event_payload(nil), do: nil

  defp event_payload(event) do
    %{
      id: event.id,
      type: event.event_type,
      recorded_at: event.recorded_at,
      progress: event.progress,
      message: event.message
    }
  end

  defp payload_for(job) do
    job_payload(job)
    |> Map.put(:job_id, job.id)
    |> Map.put(:upload_id, job.upload_id)
  end

  defp encode_sse(event, payload) do
    data = Jason.encode!(payload)
    "event: #{event}\ndata: #{data}\n\n"
  end
end
