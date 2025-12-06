defmodule LumainusWeb.ReportsLive.UploadHandlers do
  @moduledoc """
  Handles file upload events and processing for the ReportsLive LiveView.

  This module contains all upload-related event handlers and helper functions for
  processing document uploads, including preflight checks, file reading, and
  persisting uploads to the database.
  """

  alias Ecto.Changeset
  alias Lumainus.Conversion.CloudStatus
  alias Lumainus.Conversion.Service, as: ConversionService
  alias Lumainus.Documents
  alias Phoenix.LiveView
  require Logger

  @doc """
  Handles upload progress for document uploads.
  Called by LiveView when upload progress changes.
  """
  def handle_upload_progress(:documents, entry, socket) do
    Logger.debug(
      "Upload progress for #{entry.client_name}: #{entry.progress}% (done? #{entry.done?})"
    )

    if entry.done? do
      # PREFLIGHT CHECK: If cloud is selected, verify GPU is available BEFORE processing
      case preflight_backend_check(socket) do
        :ok ->
          result =
            LiveView.consume_uploaded_entry(socket, entry, fn %{path: path} ->
              case read_uploaded_file(path, entry) do
                {:ok, payload} ->
                  {:ok, {:success, payload}}

                {:error, reason} ->
                  {:ok, {:error, reason}}
              end
            end)

          Logger.debug("consume_uploaded_entry returned #{inspect(result)}")
          entry_processed(socket, result)

        {:error, reason} ->
          Logger.warning(
            "[ReportsLive] UPLOAD BLOCKED - cloud unavailable: #{entry.client_name} reason=#{reason}"
          )

          message =
            "Cloud GPU unavailable (#{reason}). Start a GPU instance or switch to Standard and re-upload."

          # Cancel the upload entry to clean up
          {:noreply,
           socket
           |> Phoenix.Component.assign(:docling_backend, :local)
           |> LiveView.cancel_upload(:documents, entry.ref)
           |> Phoenix.Component.assign(:upload_blocked_reason, message)
           |> LiveView.put_flash(
             :error,
             "Cannot upload: Cloud GPU is not available (#{reason}). Start a GPU instance or switch to Local mode."
           )}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_upload_progress(_name, _entry, socket), do: {:noreply, socket}

  @doc """
  Processes the result of consuming an uploaded entry.
  """
  def entry_processed(socket, {:ok, {:success, payload}}) do
    handle_consumed_entry(
      payload,
      socket |> Phoenix.Component.assign(:upload_blocked_reason, nil)
    )
  end

  def entry_processed(socket, {:success, payload}) do
    handle_consumed_entry(
      payload,
      socket |> Phoenix.Component.assign(:upload_blocked_reason, nil)
    )
  end

  def entry_processed(socket, {:ok, {:error, reason}}) do
    {:noreply, LiveView.put_flash(socket, :error, "Upload failed: #{inspect(reason)}")}
  end

  def entry_processed(socket, {:error, reason}) do
    {:noreply, LiveView.put_flash(socket, :error, "Upload failed: #{inspect(reason)}")}
  end

  def entry_processed(socket, {:postpone, _payload}), do: {:noreply, socket}

  def entry_processed(socket, _other), do: {:noreply, socket}

  @doc """
  Handles a successfully consumed upload entry.
  """
  def handle_consumed_entry(%{binary: binary, meta: meta}, socket) do
    lv_pid = self()
    lv_id = socket.id

    Logger.info(
      "[ReportsLive] handle_consumed_entry filename=#{meta.filename} " <>
        "byte_size=#{meta.byte_size} lv_pid=#{inspect(lv_pid)} lv_id=#{lv_id}"
    )

    case persist_upload(meta, binary, socket) do
      {:ok, updated_socket} ->
        {:noreply,
         updated_socket
         |> LiveView.put_flash(:info, "#{meta.filename} queued for ingestion.")
         |> Phoenix.Component.assign(:needs_workspace_reload, true)}

      {:error, :already_queued, updated_socket} ->
        {:noreply,
         updated_socket
         |> LiveView.put_flash(:warning, "#{meta.filename} is already being processed.")
         |> Phoenix.Component.assign(:needs_workspace_reload, true)}

      {:error, updated_socket} ->
        {:noreply, updated_socket}
    end
  end

  @doc """
  Persists an uploaded file to the database and queues it for ingestion.
  """
  def persist_upload(meta, binary, socket) do
    scope = socket.assigns.current_scope
    template = socket.assigns.template
    patient = socket.assigns.patient
    record_set = socket.assigns.record_set
    backend = socket.assigns.docling_backend
    lv_pid = self()

    case Documents.create_upload(scope, patient, record_set, meta, binary) do
      {:ok, upload} ->
        Logger.info(
          "[ReportsLive] Queuing ingestion upload=#{upload.id} filename=#{meta.filename} " <>
            "backend=#{backend} lv_pid=#{inspect(lv_pid)} record_set_id=#{record_set.id}"
        )

        case Documents.queue_ingestion(upload, template, backend: backend) do
          {:ok, _job} ->
            {:ok, socket}

          {:error, :already_queued} ->
            Logger.warning(
              "[ReportsLive] DUPLICATE BLOCKED upload=#{upload.id} filename=#{meta.filename} " <>
                "lv_pid=#{inspect(lv_pid)}"
            )

            {:error, :already_queued, socket}

          {:error, :cloud_unavailable, reason} ->
            Logger.warning(
              "[ReportsLive] CLOUD UNAVAILABLE upload=#{upload.id} filename=#{meta.filename} " <>
                "reason=#{inspect(reason)} lv_pid=#{inspect(lv_pid)}"
            )

            {:error,
             socket
             |> LiveView.put_flash(
               :error,
               "Cloud GPU is not available: #{reason}. Please start a GPU instance or switch to Local mode."
             )}

          {:error, reason} ->
            Logger.error(
              "[ReportsLive] queue_ingestion failed upload=#{upload.id} " <>
                "filename=#{meta.filename} reason=#{inspect(reason)}"
            )

            {:error,
             socket
             |> LiveView.put_flash(:error, "Failed to queue #{meta.filename}: #{inspect(reason)}")}
        end

      {:error, changeset} ->
        Logger.error("Failed to persist upload #{meta.filename}: #{humanize_errors(changeset)}")

        {:error,
         socket
         |> LiveView.put_flash(
           :error,
           "Unable to save #{meta.filename}: #{humanize_errors(changeset)}"
         )}
    end
  end

  @doc """
  Reads an uploaded file from the temporary path.
  """
  def read_uploaded_file(path, entry) do
    case File.read(path) do
      {:ok, binary} ->
        upload_meta = %{
          filename: entry.client_name,
          content_type: entry.client_type,
          byte_size: entry.client_size
        }

        {:ok, %{meta: upload_meta, binary: binary}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helper functions

  # Preflight check: if cloud backend is selected, verify GPU can accept jobs
  # Returns :ok or {:error, reason}
  # Note: With the new CloudStatus design, jobs can be accepted even when no instance
  # is running - the CloudBackend will wait for provisioning automatically.
  defp preflight_backend_check(socket) do
    backend = socket.assigns.docling_backend
    profile = profile_for_backend(backend)

    case backend do
      :cloud ->
        # Check CloudStatus for job acceptance ability
        gpu_status = check_gpu_instance_status_fast()
        cloud_status = gpu_status[:cloud_status] || %{}

        case cloud_status do
          %{can_accept_jobs: true} ->
            # Cloud can accept jobs (ready, available, or provisioning)
            if ConversionService.available?(profile),
              do: :ok,
              else: {:error, "No conversion backends available"}

          %{can_accept_jobs: false, message: message, detail: detail} ->
            {:error, "#{message}: #{detail}"}

          _ ->
            # Fallback to legacy status check
            case gpu_status do
              %{status: :running} ->
                :ok

              %{status: :loading} ->
                :ok

              %{status: :unavailable, health_check_error: error} ->
                {:error, error}

              %{status: :unknown, health_check_error: error} ->
                {:error, error || "GPU status unknown"}
            end
        end

      # Local backends don't need preflight check
      _ ->
        if ConversionService.available?(profile) do
          :ok
        else
          {:error, "No conversion backends available"}
        end
    end
  end

  # Fast version that only checks local state - NO HTTP calls
  # Used during mount to avoid blocking page load
  # Returns map with: status, endpoint, instance_id, healthy, health_check_error, cloud_status
  # Uses CloudStatus as single source of truth for cloud backend availability
  defp check_gpu_instance_status_fast do
    cloud_status = CloudStatus.get()

    # Convert CloudStatus to legacy format for backward compatibility with UI
    case cloud_status do
      %{availability: :ready, endpoint: endpoint, instance_info: info} ->
        %{
          status: :running,
          endpoint: endpoint,
          instance_id: get_in(info || %{}, [:instance_id]),
          healthy: true,
          health_check_error: nil,
          cloud_status: cloud_status
        }

      %{availability: :provisioning, endpoint: endpoint, instance_info: info} ->
        # Could be loading or running-but-unhealthy
        instance_status = get_in(info || %{}, [:status])

        %{
          status: if(instance_status == :running, do: :running, else: :loading),
          endpoint: endpoint,
          instance_id: get_in(info || %{}, [:instance_id]),
          healthy: false,
          health_check_error: "Starting up...",
          cloud_status: cloud_status
        }

      %{availability: :unavailable, message: _message} ->
        %{
          status: :unavailable,
          endpoint: nil,
          instance_id: nil,
          healthy: false,
          health_check_error: cloud_status[:detail],
          cloud_status: cloud_status
        }

      _ ->
        %{
          status: :unknown,
          endpoint: nil,
          instance_id: nil,
          healthy: nil,
          health_check_error: "CloudStatus unavailable",
          cloud_status: cloud_status
        }
    end
  end

  defp profile_for_backend(%{conversion_profile: profile}) do
    normalize_conversion_profile(profile) || :standard
  end

  defp profile_for_backend(backend) do
    case normalize_backend_atom(backend) do
      :cloud -> :enhanced
      _ -> :standard
    end
  end

  defp normalize_backend_atom(nil), do: :local
  defp normalize_backend_atom(:local), do: :local
  defp normalize_backend_atom("local"), do: :local
  defp normalize_backend_atom(:cloud), do: :cloud
  defp normalize_backend_atom("cloud"), do: :cloud
  defp normalize_backend_atom(:fast), do: :cloud
  defp normalize_backend_atom("fast"), do: :cloud
  defp normalize_backend_atom(_), do: :local

  defp normalize_conversion_profile(:enhanced), do: :enhanced
  defp normalize_conversion_profile("enhanced"), do: :enhanced
  defp normalize_conversion_profile(:standard), do: :standard
  defp normalize_conversion_profile("standard"), do: :standard
  defp normalize_conversion_profile(_), do: nil

  defp humanize_errors(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} ->
      "#{humanize_field(field)} #{List.first(messages)}"
    end)
    |> Enum.join(", ")
  end

  defp humanize_field(field) when is_atom(field) do
    field
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
