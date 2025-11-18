defmodule LumainusWeb.Api.UploadController do
  use LumainusWeb, :controller

  alias Lumainus.Accounts.Scope
  alias Lumainus.Documents
  alias Lumainus.Documents.DocumentUpload
  alias Lumainus.Reports
  alias Lumainus.Repo
  alias Lumainus.Tenancy.Tenant

  action_fallback LumainusWeb.ApiFallbackController

  def create(conn, %{"file" => %Plug.Upload{} = upload}) do
    with {:ok, scope, workspace} <- resolve_workspace(conn.params),
         {:ok, binary} <- File.read(upload.path),
         {:ok, document} <- persist_upload(scope, workspace, upload, binary) do
      json(conn, %{
        upload_id: document.id,
        status: document.status,
        filename: document.filename,
        queued_job: "pdf_ingest"
      })
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Expected multipart/form-data with a file field"})
  end

  def status(conn, %{"id" => upload_id}) do
    with {:ok, status} <- Documents.fetch_upload_status(upload_id) do
      json(conn, %{
        upload: upload_payload(status.upload),
        job: job_payload(status.job),
        latest_event: event_payload(status.latest_event)
      })
    end
  end

  defp resolve_workspace(params) do
    tenant_id = Map.get(params, "tenant_id") || default_tenant_id()

    case Repo.get(Tenant, tenant_id) do
      %Tenant{} = tenant ->
        scope = %Scope{tenant_id: tenant.id, tenant: tenant, user: nil}
        workspace = Reports.workspace(scope)
        {:ok, scope, workspace}

      _ ->
        {:error, :tenant_not_found}
    end
  end

  defp default_tenant_id do
    Tenant
    |> Repo.one!()
    |> Map.fetch!(:id)
  end

  defp persist_upload(scope, workspace, upload, binary) do
    meta = %{
      filename: upload.filename || "upload.pdf",
      content_type: upload.content_type || "application/pdf",
      byte_size: byte_size(binary)
    }

    case existing_upload(scope.tenant_id, binary) do
      %DocumentUpload{} = record ->
        {:ok, record}

      nil ->
        with {:ok, record} <-
               Documents.create_upload(
                 scope,
                 workspace.patient,
                 workspace.record_set,
                 meta,
                 binary
               ) do
          Documents.queue_ingestion(record, workspace.template)
          {:ok, record}
        end
    end
  end

  defp existing_upload(tenant_id, binary) do
    digest =
      :crypto.hash(:sha256, binary)
      |> Base.encode16(case: :lower)

    DocumentUpload
    |> Repo.get_by(tenant_id: tenant_id, sha256: digest)
  end

  defp upload_payload(nil), do: nil

  defp upload_payload(upload) do
    %{
      id: upload.id,
      record_set_id: upload.record_set_id,
      status: upload.status,
      filename: upload.filename,
      metadata: upload.metadata,
      inserted_at: upload.inserted_at,
      updated_at: upload.updated_at
    }
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
      events: Enum.map(sort_events(job.events || []), &event_payload/1)
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

  defp sort_events(events) do
    Enum.sort_by(events, fn event ->
      event.recorded_at || DateTime.from_unix!(0, :second)
    end)
  end
end
