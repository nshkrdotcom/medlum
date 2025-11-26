defmodule LumainusWeb.ReportsLive do
  use LumainusWeb, :live_view

  alias Ecto.Changeset
  alias Lumainus.Accounts
  alias Lumainus.Docling
  alias Lumainus.Docling.VastAI.InstanceManager
  alias Lumainus.Docling.VastAI.ProvisioningState
  alias Lumainus.Docling.Settings, as: DoclingSettings
  alias Lumainus.Cloudflare
  alias Lumainus.Documents
  alias Lumainus.Clinical.{Patients, RecordSets}
  alias Lumainus.Reports
  alias Lumainus.VastAI
  alias Lumainus.VastAI.Instances, as: VastAIInstances
  alias Lumainus.VastAI.Offers, as: VastAIOffers
  alias MapSet
  alias Path
  alias Phoenix.LiveView.JS
  alias LumainusWeb.Markdown
  import LumainusWeb.Components.ProgressStages
  require Logger

  @document_modal_tabs [
    %{id: "summary", label: "Summary"},
    %{id: "cleaned", label: "Cleaned text"},
    %{id: "raw", label: "Raw PDF text"}
  ]
  @document_modal_tab_ids Enum.map(@document_modal_tabs, & &1.id)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    Reports.bootstrap_workspace!(scope)

    socket =
      socket
      |> allow_upload(:documents,
        accept: ~w(.pdf),
        max_entries: 5,
        max_file_size: 25_000_000,
        auto_upload: true,
        progress: &handle_upload_progress/3
      )
      |> load_workspace()

    socket =
      if connected?(socket) do
        Documents.subscribe_to_record_set(socket.assigns.record_set.id)

        assign(
          socket,
          :record_set_subscriptions,
          MapSet.put(socket.assigns.record_set_subscriptions, socket.assigns.record_set.id)
        )
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("select_document", %{"doc-id" => doc_id}, socket) do
    current = socket.assigns.selected_document
    doc = find_document_by_id(socket.assigns.documents, doc_id)

    cond do
      is_nil(doc) ->
        {:noreply, socket}

      current && current.id == doc.id ->
        {:noreply, assign(socket, selected_document: nil)}

      true ->
        {:noreply, assign(socket, selected_document: doc)}
    end
  end

  @impl true
  def handle_event("clear_document", _params, socket) do
    {:noreply, assign(socket, selected_document: nil)}
  end

  @impl true
  def handle_event("open_document_modal", %{"doc-id" => doc_id}, socket) do
    Logger.debug("Looking for document with ID: #{inspect(doc_id)}")

    Logger.debug(
      "Available documents: #{inspect(Enum.map(socket.assigns.documents, &{&1.id, &1.sequence, &1.mock_id}))}"
    )

    case find_document_by_id(socket.assigns.documents, doc_id) do
      nil ->
        Logger.warning("Document not found for ID: #{inspect(doc_id)}")

        {:noreply,
         put_flash(
           socket,
           :error,
           "Document reference '#{doc_id}' not found. Available docs: #{Enum.map(socket.assigns.documents, & &1.sequence) |> Enum.join(", ")}"
         )}

      doc ->
        Logger.debug("Found document: #{inspect(doc.label)}")

        {:noreply,
         socket
         |> assign(:document_modal_document, doc)
         |> assign(:document_modal_tab, "summary")
         |> assign(:document_modal_open, true)}
    end
  end

  @impl true
  def handle_event("close_document_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:document_modal_document, nil)
     |> assign(:document_modal_open, false)}
  end

  @impl true
  def handle_event("switch_document_modal_tab", %{"tab" => tab}, socket) do
    tab = to_string(tab)

    if tab in @document_modal_tab_ids do
      {:noreply, assign(socket, :document_modal_tab, tab)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("run_section", %{"section-id" => section_id}, socket) do
    run_sections(socket, [section_id])
  end

  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("set_docling_backend", %{"backend" => backend}, socket) do
    # Only admins can change backend
    unless socket.assigns.can_manage_gpu? do
      {:noreply,
       put_flash(socket, :error, "You don't have permission to change processing mode.")}
    else
      backend_atom =
        backend
        |> String.downcase()
        |> Docling.normalize_user_backend()

      cond do
        backend_atom == :cloud and not socket.assigns.fast_available? ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Cloud (GPU) is unavailable right now. Using Local until it recovers."
           )}

        true ->
          case Accounts.update_docling_backend(socket.assigns.current_scope.user, backend_atom) do
            {:ok, user} ->
              scope = %{socket.assigns.current_scope | user: user}

              {:noreply,
               socket
               |> assign(:docling_backend, backend_atom)
               |> assign(:current_scope, scope)
               |> maybe_fast_cost_flash(backend_atom)}

            {:error, changeset} ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 "Unable to save preference: #{humanize_errors(changeset)}"
               )}
          end
      end
    end
  rescue
    _ ->
      {:noreply, put_flash(socket, :error, "Unknown processing mode.")}
  end

  def handle_event("boot_gpu_and_enable", _params, socket) do
    # Only admins can boot GPU instances
    unless socket.assigns.can_manage_gpu? do
      {:noreply, put_flash(socket, :error, "You don't have permission to manage GPU instances.")}
    else
      # SAFETY CHECK: Prevent duplicate provisioning
      # Check if there's already an instance running before starting provisioning
      case InstanceManager.check_existing_instance() do
        {:ok, endpoint} when is_binary(endpoint) ->
          # Already have an endpoint tracked - just update user preference
          Logger.info(
            "[ReportsLive] GPU instance already exists at #{endpoint}, skipping provisioning"
          )

          socket =
            case Accounts.update_docling_backend(socket.assigns.current_scope.user, :cloud) do
              {:ok, user} ->
                scope = %{socket.assigns.current_scope | user: user}
                socket |> assign(:docling_backend, :cloud) |> assign(:current_scope, scope)

              {:error, _} ->
                socket
            end

          {:noreply,
           socket
           |> assign(:gpu_prompt_dismissed, true)
           |> put_flash(:info, "GPU instance already running! Cloud mode enabled.")
           |> push_navigate(to: ~p"/admin/vast_ai")}

        {:ok, :running, instance_id} ->
          # Instance exists on Vast.ai but not tracked - log warning and redirect
          Logger.warning(
            "[ReportsLive] Found untracked running instance #{instance_id} on Vast.ai"
          )

          socket =
            case Accounts.update_docling_backend(socket.assigns.current_scope.user, :cloud) do
              {:ok, user} ->
                scope = %{socket.assigns.current_scope | user: user}
                socket |> assign(:docling_backend, :cloud) |> assign(:current_scope, scope)

              {:error, _} ->
                socket
            end

          {:noreply,
           socket
           |> assign(:gpu_prompt_dismissed, true)
           |> put_flash(
             :warning,
             "Found existing GPU instance ##{instance_id}. Check admin page for status."
           )
           |> push_navigate(to: ~p"/admin/vast_ai")}

        {:ok, :none} ->
          # No instance exists - proceed with provisioning
          socket =
            case Accounts.update_docling_backend(socket.assigns.current_scope.user, :cloud) do
              {:ok, user} ->
                scope = %{socket.assigns.current_scope | user: user}
                socket |> assign(:docling_backend, :cloud) |> assign(:current_scope, scope)

              {:error, _} ->
                socket
            end

          # Start async provisioning in background (uses ProvisioningState for real-time logs)
          Task.start(fn -> auto_provision_gpu() end)

          {:noreply,
           socket
           |> assign(:gpu_prompt_dismissed, true)
           |> put_flash(:info, "Starting GPU provisioning... Watch progress below.")
           |> push_navigate(to: ~p"/admin/vast_ai")}

        {:error, reason} ->
          Logger.error("[ReportsLive] Failed to check existing instances: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, "Failed to check GPU status. Please try again.")}
      end
    end
  end

  def handle_event("dismiss_gpu_prompt", _params, socket) do
    {:noreply, assign(socket, :gpu_prompt_dismissed, true)}
  end

  # Start a stopped GPU instance
  def handle_event("start_gpu", _params, socket) do
    unless socket.assigns.can_manage_gpu? do
      {:noreply, put_flash(socket, :error, "You don't have permission to manage GPU instances.")}
    else
      case InstanceManager.start_instance() do
        {:ok, endpoint} ->
          Logger.info("[ReportsLive] GPU instance started, endpoint: #{endpoint}")

          # Update user preference to cloud
          socket =
            case Accounts.update_docling_backend(socket.assigns.current_scope.user, :cloud) do
              {:ok, user} ->
                scope = %{socket.assigns.current_scope | user: user}
                socket |> assign(:docling_backend, :cloud) |> assign(:current_scope, scope)

              {:error, _} ->
                socket
            end

          {:noreply,
           socket
           |> assign(:gpu_instance_status, %{
             status: :running,
             endpoint: endpoint,
             instance_id: socket.assigns.gpu_instance_status[:instance_id]
           })
           |> assign(:fast_available?, nil)
           |> assign(:fast_unavailable_reason, "Checking...")
           |> put_flash(:info, "GPU instance starting... This may take a moment.")}

        {:error, :no_instance} ->
          {:noreply,
           put_flash(socket, :error, "No GPU instance exists. Contact admin to provision one.")}

        {:error, :instance_loading} ->
          {:noreply, put_flash(socket, :info, "GPU instance is already starting...")}

        {:error, reason} ->
          Logger.error("[ReportsLive] Failed to start GPU: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, "Failed to start GPU: #{inspect(reason)}")}
      end
    end
  end

  # Stop a running GPU instance
  def handle_event("stop_gpu", _params, socket) do
    unless socket.assigns.can_manage_gpu? do
      {:noreply, put_flash(socket, :error, "You don't have permission to manage GPU instances.")}
    else
      case InstanceManager.stop_instance() do
        :ok ->
          Logger.info("[ReportsLive] GPU instance stopped")

          {:noreply,
           socket
           |> assign(:gpu_instance_status, %{
             status: :stopped,
             endpoint: nil,
             instance_id: socket.assigns.gpu_instance_status[:instance_id]
           })
           |> assign(:fast_available?, false)
           |> assign(:fast_unavailable_reason, "GPU instance stopped")
           |> put_flash(:info, "GPU instance stopped. Start it again when needed.")}

        {:error, :no_instance} ->
          {:noreply, put_flash(socket, :info, "No GPU instance to stop.")}

        {:error, reason} ->
          Logger.error("[ReportsLive] Failed to stop GPU: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, "Failed to stop GPU: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("run_full_report", _params, socket) do
    section_ids = Enum.map(socket.assigns.sections, & &1.section.id)
    run_sections(socket, section_ids)
  end

  def handle_event("seed_sample_documents", _params, socket) do
    scope = socket.assigns.current_scope

    case Documents.seed_sample_documents(scope, socket.assigns.patient, socket.assigns.record_set) do
      {:ok, :noop} ->
        {:noreply,
         put_flash(socket, :info, "Sample documents already loaded.") |> load_workspace()}

      {:ok, uploads} ->
        {:noreply,
         socket
         |> put_flash(:info, "Loaded #{length(uploads)} sample documents.")
         |> load_workspace()}
    end
  end

  @impl true
  def handle_event("delete_document", %{"doc-id" => doc_id}, socket) do
    scope = socket.assigns.current_scope

    case Documents.delete_upload(scope, doc_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:selected_document, nil)
         |> put_flash(:info, "Document removed.")
         |> load_workspace()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Document no longer exists.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unable to delete: #{inspect(reason)}")}
    end
  end

  def handle_event("retry_ingestion", %{"doc-id" => doc_id}, socket) do
    template = socket.assigns.template

    case find_document_by_id(socket.assigns.documents, doc_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Document no longer exists.")}

      doc ->
        case Documents.retry_ingestion(doc.id,
               template: template,
               backend: socket.assigns.docling_backend
             ) do
          {:ok, _job} ->
            {:noreply,
             socket
             |> put_flash(:info, "Retry queued for #{doc.label}.")
             |> load_workspace()}

          {:error, :template_required} ->
            {:noreply,
             socket
             |> put_flash(:error, "A template is required to retry ingestion.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Unable to retry: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("open_patient_modal", _params, socket) do
    {:noreply, assign(socket, :patient_modal_open, true)}
  end

  def handle_event("close_patient_modal", _params, socket) do
    {:noreply, assign(socket, :patient_modal_open, false)}
  end

  def handle_event("select_patient", %{"patient_id" => patient_id}, socket) do
    {:noreply,
     socket
     |> assign(:patient_modal_open, false)
     |> load_workspace(patient_id: patient_id)}
  end

  def handle_event("create_patient", _params, socket) do
    scope = socket.assigns.current_scope

    case Reports.create_patient_for_scope(scope) do
      {:ok, patient} ->
        {:noreply,
         socket
         |> put_flash(:info, "New patient created.")
         |> assign(:patient_modal_open, false)
         |> load_workspace(patient_id: patient.id)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to create patient: #{humanize_errors(changeset)}")}
    end
  end

  def handle_event("select_record_set", %{"id" => record_set_id}, socket) do
    {:noreply,
     socket
     |> assign(:patient_modal_open, false)
     |> load_workspace(record_set_id: record_set_id)}
  end

  def handle_event("create_record_set", _params, socket) do
    case RecordSets.create_record_set(socket.assigns.patient) do
      {:ok, record_set} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{record_set.label} created.")
         |> assign(:patient_modal_open, false)
         |> load_workspace(record_set_id: record_set.id)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to create workspace: #{humanize_errors(changeset)}")}
    end
  end

  def handle_event("validate_patient_profile", %{"profile" => params}, socket) do
    form = profile_form(socket.assigns.patient, params, :validate)
    {:noreply, assign(socket, :profile_form, form)}
  end

  def handle_event("save_patient_profile", %{"profile" => params}, socket) do
    case Patients.update_profile(socket.assigns.patient, params) do
      {:ok, _patient} ->
        {:noreply,
         socket
         |> put_flash(:info, "Patient details saved.")
         |> load_workspace()}

      {:error, changeset} ->
        form = profile_form_from_changeset(changeset, :validate)
        {:noreply, assign(socket, :profile_form, form)}
    end
  end

  defp run_sections(socket, section_ids) do
    scope = socket.assigns.current_scope

    case Reports.run_sections(
           scope,
           socket.assigns.patient,
           socket.assigns.record_set,
           socket.assigns.template,
           section_ids
         ) do
      {:ok, _run} ->
        {:noreply, load_workspace(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Report generation failed: #{inspect(reason)}")
         |> load_workspace()}
    end
  end

  defp load_workspace(socket, opts \\ []) do
    scope = socket.assigns.current_scope
    has_patient_override = Keyword.has_key?(opts, :patient_id)

    record_set_id =
      if has_patient_override do
        Keyword.get(opts, :record_set_id)
      else
        Keyword.get(opts, :record_set_id) || socket.assigns[:active_record_set_id]
      end

    patient_id =
      Keyword.get(opts, :patient_id) || (socket.assigns[:patient] && socket.assigns.patient.id)

    workspace = Reports.workspace(scope, record_set_id: record_set_id, patient_id: patient_id)
    documents = format_documents(workspace.documents)
    sections = format_sections(workspace.sections)
    docling_health = Docling.latest_health_check()

    # NON-BLOCKING: Get GPU status quickly (checks local state, not HTTP)
    gpu_instance_status = check_gpu_instance_status_fast()

    # NON-BLOCKING: Defer expensive health check to avoid blocking page load
    # Start with "checking" state and update async after mount
    {fast_available?, fast_reason} =
      case gpu_instance_status.status do
        # Will be updated async
        :running -> {nil, "Checking..."}
        :loading -> {false, "GPU instance still loading"}
        _ -> {false, "No GPU instance"}
      end

    # Schedule async health check if we have a potential endpoint
    if connected?(socket) and gpu_instance_status.status == :running do
      send(self(), :check_fast_backend_health)
    end

    # Doctors always use local backend (no GPU cost controls)
    can_manage_gpu? = scope.user.role in ["admin", "system_administrator"]

    selected_backend =
      if can_manage_gpu? do
        preferred_backend = Accounts.docling_backend_for_user(scope.user)
        # Only fall back to local if fast is explicitly unavailable (false)
        # When fast_available? is nil (Checking), allow cloud backend
        if preferred_backend == :fast and fast_available? == false,
          do: :local,
          else: preferred_backend
      else
        :local
      end

    running_sections =
      sections
      |> Enum.filter(&(&1.status in ["running", "queued"]))
      |> Enum.map(& &1.section.id)
      |> MapSet.new()

    record_sets = RecordSets.list_for_patient(workspace.patient)
    record_set_latest_runs = Reports.latest_runs_for_record_sets(scope, record_sets)
    recent_runs = Reports.list_runs_for_record_set(scope, workspace.record_set, limit: 5)
    patients = Reports.list_patients_for_scope(scope)

    socket =
      socket
      |> assign(:patient, workspace.patient)
      |> assign(:record_set, workspace.record_set)
      |> assign(:template, workspace.template)
      |> assign(:documents, documents)
      |> assign(:sections, sections)
      |> assign(:running_sections, running_sections)
      |> assign(:record_sets, record_sets)
      |> assign(:record_set_latest_runs, record_set_latest_runs)
      |> assign(:recent_runs, recent_runs)
      |> assign(:patients, patients)
      |> assign(:docling_health, docling_health)
      |> assign(:docling_backend, selected_backend)
      |> assign(:fast_available?, fast_available?)
      |> assign(:fast_unavailable_reason, format_backend_reason(fast_reason))
      |> assign(:gpu_instance_status, gpu_instance_status)
      |> assign(:can_manage_gpu?, can_manage_gpu?)
      |> assign(:profile_form, profile_form(workspace.patient))
      |> assign(:active_record_set_id, workspace.record_set.id)
      |> assign(:selected_document, nil)
      |> assign(:document_modal_document, nil)
      |> assign(:document_modal_open, false)
      |> assign(:document_modal_tab, "summary")
      |> assign_new(:patient_modal_open, fn -> false end)
      |> assign_new(:gpu_prompt_dismissed, fn -> false end)
      |> assign_new(:gpu_provisioning, fn -> false end)
      |> assign_new(:job_subscriptions, fn -> MapSet.new() end)
      |> assign_new(:record_set_subscriptions, fn -> MapSet.new() end)
      |> assign_new(:report_run_subscriptions, fn -> MapSet.new() end)
      |> assign(:health_check_retry_count, 0)

    socket
    |> maybe_refresh_document_modal()
    |> maybe_subscribe_record_set(workspace.record_set.id)
    |> maybe_subscribe_report_runs(workspace.record_set.id)
    |> subscribe_to_job_topics()
  end

  @impl true
  def handle_info({:documents_changed, record_set_id}, socket) do
    if socket.assigns.record_set.id == record_set_id do
      {:noreply, load_workspace(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:job_progress, record_set_id, payload}, socket) do
    if socket.assigns.record_set.id == record_set_id do
      updated = update_document_progress(socket.assigns.documents, payload)
      {:noreply, assign(socket, :documents, updated)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:section_run_updated, record_set_id}, socket) do
    if socket.assigns.record_set.id == record_set_id do
      {:noreply, load_workspace(socket)}
    else
      {:noreply, socket}
    end
  end

  # Async health check to avoid blocking page load
  def handle_info(:check_fast_backend_health, socket) do
    # Capture LiveView pid before starting task
    lv_pid = self()

    # Run health check in background with short timeout
    Task.start(fn ->
      result = fast_backend_health_with_timeout(5_000)
      send(lv_pid, {:fast_backend_health_result, result})
    end)

    {:noreply, socket}
  end

  def handle_info({:fast_backend_health_result, {available?, reason}}, socket) do
    # When health check fails but we know an instance exists, show better status
    # This handles the case where instance was just provisioned but service is still booting
    #
    # IMPORTANT: Check InstanceManager directly for current state, not socket assigns
    # which may be stale from page load
    current_instance_status = check_gpu_instance_status_fast()

    {final_available?, final_reason, should_retry?} =
      case {available?, current_instance_status} do
        {true, _} ->
          # Health check passed - all good
          {true, nil, false}

        {false, %{status: :running, endpoint: endpoint}}
        when is_binary(endpoint) and endpoint != "" ->
          # Instance exists but health check failed - service is probably still starting
          # (Caddy installing, SSL certs, etc.)
          Logger.info(
            "[ReportsLive] Health check failed but instance exists at #{endpoint} - service starting"
          )

          {false, "Service starting (GPU instance running, waiting for service to be ready)...",
           true}

        {false, %{status: :loading}} ->
          # Instance still loading
          {false, "GPU instance still loading...", true}

        {false, _} ->
          # No instance or truly unavailable
          {false, reason, false}
      end

    # Also update the gpu_instance_status assign to match current reality
    socket = assign(socket, :gpu_instance_status, current_instance_status)

    socket =
      socket
      |> assign(:fast_available?, final_available?)
      |> assign(:fast_reason, final_reason)
      |> assign(:fast_unavailable_reason, format_backend_reason(final_reason))

    # Auto-retry health check if instance exists but service not ready yet
    # Retry every 10 seconds up to a reasonable limit
    retry_count = Map.get(socket.assigns, :health_check_retry_count, 0)
    # 3 minutes of retrying (18 * 10 seconds)
    max_retries = 18

    socket =
      cond do
        # Health check passed - reset retry count
        final_available? == true ->
          if retry_count > 0 do
            Logger.info("[ReportsLive] Health check succeeded after #{retry_count} retries")
          end

          assign(socket, :health_check_retry_count, 0)

        # Should retry and haven't exhausted retries
        should_retry? and retry_count < max_retries ->
          Logger.debug(
            "[ReportsLive] Scheduling health check retry #{retry_count + 1}/#{max_retries} in 10s"
          )

          Process.send_after(self(), :check_fast_backend_health, 10_000)
          assign(socket, :health_check_retry_count, retry_count + 1)

        # Exhausted retries
        retry_count >= max_retries ->
          Logger.warning(
            "[ReportsLive] Health check retries exhausted after #{max_retries} attempts"
          )

          socket

        # Not retrying
        true ->
          socket
      end

    # If health check failed with connection error, trigger a sync
    # This handles cases where the instance was deleted externally
    # But only if we don't have a known instance (to avoid syncing when just booting)
    if final_available? == false and is_binary(reason) and
         (String.contains?(reason, "timeout") or String.contains?(reason, "econnrefused") or
            String.contains?(reason, "nxdomain") or String.contains?(reason, "transport_error")) do
      # Only sync if we don't think an instance exists (use fresh status, not stale assigns)
      if current_instance_status.status not in [:running, :loading] do
        Logger.info(
          "[ReportsLive] Health check failed with connection error, triggering Vast.ai sync"
        )

        send(self(), :trigger_vast_ai_sync)
      end
    end

    {:noreply, socket}
  end

  def handle_info(:trigger_vast_ai_sync, socket) do
    # Run sync in background to not block
    lv_pid = self()

    Task.start(fn ->
      result = InstanceManager.sync_with_vast_ai()
      send(lv_pid, {:vast_ai_sync_result, result})
    end)

    {:noreply, socket}
  end

  def handle_info({:vast_ai_sync_result, result}, socket) do
    case result do
      {:ok, :synced, endpoint} ->
        Logger.info("[ReportsLive] Sync found and adopted instance at #{endpoint}")
        # Update status and trigger fresh health check
        socket =
          socket
          |> assign(:gpu_instance_status, %{status: :running, endpoint: endpoint})
          |> assign(:fast_available?, nil)
          |> assign(:fast_reason, "Checking...")
          |> assign(:fast_unavailable_reason, "Checking...")
          |> assign(:health_check_retry_count, 0)
          |> put_flash(:info, "Found running GPU instance at #{endpoint}")

        # Trigger fresh health check
        send(self(), :check_fast_backend_health)
        {:noreply, socket}

      {:ok, :cleared} ->
        Logger.info("[ReportsLive] Sync cleared stale instance state")
        # Update all related assigns
        {:noreply,
         socket
         |> assign(:gpu_instance_status, %{status: :no_instance, endpoint: nil})
         |> assign(:fast_available?, false)
         |> assign(:fast_reason, "No GPU instance")
         |> assign(:fast_unavailable_reason, "No GPU instance")
         |> assign(:health_check_retry_count, 0)}

      {:ok, :unchanged} ->
        {:noreply, socket}

      {:ok, :loading, id} ->
        Logger.info("[ReportsLive] Instance #{id} still loading")

        {:noreply,
         socket
         |> assign(:gpu_instance_status, %{status: :loading, endpoint: nil})
         |> assign(:fast_available?, false)
         |> assign(:fast_reason, "GPU instance still loading...")
         |> assign(:fast_unavailable_reason, "GPU instance still loading...")}

      {:error, reason} ->
        Logger.warning("[ReportsLive] Sync failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp handle_upload_progress(:documents, entry, socket) do
    Logger.debug(
      "Upload progress for #{entry.client_name}: #{entry.progress}% (done? #{entry.done?})"
    )

    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          case read_uploaded_file(path, entry) do
            {:ok, payload} ->
              {:ok, {:success, payload}}

            {:error, reason} ->
              {:ok, {:error, reason}}
          end
        end)

      Logger.debug("consume_uploaded_entry returned #{inspect(result)}")
      entry_processed(socket, result)
    else
      {:noreply, socket}
    end
  end

  defp handle_upload_progress(_name, _entry, socket), do: {:noreply, socket}

  defp entry_processed(socket, {:ok, {:success, payload}}) do
    handle_consumed_entry(payload, socket)
  end

  defp entry_processed(socket, {:success, payload}) do
    handle_consumed_entry(payload, socket)
  end

  defp entry_processed(socket, {:ok, {:error, reason}}) do
    {:noreply, put_flash(socket, :error, "Upload failed: #{inspect(reason)}")}
  end

  defp entry_processed(socket, {:error, reason}) do
    {:noreply, put_flash(socket, :error, "Upload failed: #{inspect(reason)}")}
  end

  defp entry_processed(socket, {:postpone, _payload}), do: {:noreply, socket}

  defp entry_processed(socket, _other), do: {:noreply, socket}

  defp handle_consumed_entry(%{binary: binary, meta: meta}, socket) do
    Logger.debug("ReportsLive received upload #{meta.filename} (#{meta.byte_size} bytes)")

    case persist_upload(meta, binary, socket) do
      {:ok, updated_socket} ->
        {:noreply,
         updated_socket
         |> put_flash(:info, "#{meta.filename} queued for ingestion.")
         |> load_workspace()}

      {:error, updated_socket} ->
        {:noreply, updated_socket}
    end
  end

  defp persist_upload(meta, binary, socket) do
    scope = socket.assigns.current_scope
    template = socket.assigns.template
    patient = socket.assigns.patient
    record_set = socket.assigns.record_set

    case Documents.create_upload(scope, patient, record_set, meta, binary) do
      {:ok, upload} ->
        Documents.queue_ingestion(upload, template, backend: socket.assigns.docling_backend)
        {:ok, socket}

      {:error, changeset} ->
        Logger.error("Failed to persist upload #{meta.filename}: #{humanize_errors(changeset)}")

        {:error,
         socket
         |> put_flash(:error, "Unable to save #{meta.filename}: #{humanize_errors(changeset)}")}
    end
  end

  defp read_uploaded_file(path, entry) do
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

  defp format_documents(documents) do
    documents
    |> Enum.with_index(1)
    |> Enum.map(fn {doc, index} ->
      parse = List.first(doc.parses || [])
      metadata = doc.metadata || %{}
      label = metadata["label"] || Path.rootname(doc.filename)
      summary = metadata["summary"] || "Awaiting ingestion"
      provider = metadata["provider"] || "Unknown source"
      date = metadata["date"] || Calendar.strftime(doc.inserted_at, "%Y-%m-%d")
      ingestion_state = metadata["ingestion_state"]
      ingestion_stage = metadata["ingestion_stage"]
      ingestion_progress = metadata["ingestion_progress"] || 0
      ingestion_message = metadata["ingestion_message"]
      ingestion_error = metadata["ingestion_error"]
      job_id = metadata["ingestion_job_id"]
      status = ingestion_state || doc.status || metadata["status"] || ingestion_stage
      timeout_at = metadata["ingestion_timeout_at"]
      progress_payload = metadata["progress"] || %{}
      backend = metadata["docling_backend"] || metadata["backend"] || "local"
      backend_status = metadata["docling_backend_status"]

      %{
        id: doc.id,
        sequence: index,
        filename: doc.filename,
        mock_id: metadata["mock_id"],
        label: label,
        summary: summary,
        provider: provider,
        date: date,
        kind: doc.document_kind,
        cleaned_content: parse && parse.parsed_text,
        raw_content: doc.raw_blob,
        status: status,
        ingestion_state: ingestion_state || status,
        ingestion_stage: ingestion_stage,
        ingestion_progress: ingestion_progress,
        ingestion_message: ingestion_message,
        ingestion_error: ingestion_error,
        ingestion_job_id: job_id,
        ingestion_timeout_at: timeout_at,
        progress: progress_payload,
        backend: backend,
        backend_status: backend_status,
        uploaded_at: doc.inserted_at,
        ingested_at: doc.ingested_at,
        byte_size: doc.byte_size,
        content_type: doc.content_type,
        byte_size_label: format_byte_size(doc.byte_size)
      }
    end)
  end

  defp format_sections(entries) do
    Enum.map(entries, fn %{section: section, latest_run: run} = entry ->
      %{
        section: section,
        last_run: format_run(run),
        status: run_status(entry)
      }
    end)
  end

  defp find_document_by_id(documents, doc_id) do
    doc_id = to_string(doc_id)

    # First try to find by actual document ID (UUID)
    # Then try to find by sequence number (e.g., "101" for doc-101)
    # Finally try to find by mock_id (e.g., "doc-101")
    Enum.find(documents, &(to_string(&1.id) == doc_id)) ||
      Enum.find(documents, &(to_string(&1.sequence) == doc_id)) ||
      Enum.find(documents, &(&1.mock_id && to_string(&1.mock_id) == doc_id))
  end

  defp maybe_refresh_document_modal(%{assigns: assigns} = socket) do
    cond do
      not Map.has_key?(assigns, :document_modal_document) ->
        socket

      is_nil(assigns.document_modal_document) ->
        socket

      true ->
        doc_id = assigns.document_modal_document.id

        case find_document_by_id(assigns.documents, doc_id) do
          nil ->
            socket
            |> assign(:document_modal_document, nil)
            |> assign(:document_modal_open, false)

          doc ->
            assign(socket, :document_modal_document, doc)
        end
    end
  end

  defp document_modal_tabs, do: @document_modal_tabs

  defp subscribe_to_job_topics(socket) do
    if connected?(socket) do
      job_ids =
        socket.assigns.documents
        |> Enum.map(& &1.ingestion_job_id)
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()

      new_ids = MapSet.difference(job_ids, socket.assigns.job_subscriptions)

      Enum.each(new_ids, &Documents.subscribe_to_ingestion_job/1)

      assign(socket, :job_subscriptions, MapSet.union(socket.assigns.job_subscriptions, new_ids))
    else
      socket
    end
  end

  defp maybe_subscribe_record_set(socket, record_set_id) do
    if connected?(socket) and
         not MapSet.member?(socket.assigns.record_set_subscriptions, record_set_id) do
      Documents.subscribe_to_record_set(record_set_id)

      assign(
        socket,
        :record_set_subscriptions,
        MapSet.put(socket.assigns.record_set_subscriptions, record_set_id)
      )
    else
      socket
    end
  end

  defp maybe_subscribe_report_runs(socket, record_set_id) do
    if connected?(socket) and
         not MapSet.member?(socket.assigns.report_run_subscriptions, record_set_id) do
      Reports.subscribe_to_section_runs(record_set_id)

      assign(
        socket,
        :report_run_subscriptions,
        MapSet.put(socket.assigns.report_run_subscriptions, record_set_id)
      )
    else
      socket
    end
  end

  # Health check with explicit timeout for async calls
  defp fast_backend_health_with_timeout(timeout_ms) do
    config = Docling.config()
    cloud_url = Keyword.get(config, :cloud_url)
    remote_url = Keyword.get(config, :remote_url)

    cond do
      is_nil(cloud_url) and is_nil(remote_url) ->
        {false, "Cloud URL not configured"}

      cloud_url == "" and (is_nil(remote_url) or remote_url == "") ->
        {false, "Cloud URL not configured"}

      true ->
        try do
          # Use Task with timeout to avoid hanging forever
          task =
            Task.async(fn ->
              case Docling.health(backend: :vast_ai, timeout: timeout_ms) do
                {:ok, _} -> {true, nil}
                {:error, reason} -> {false, inspect(reason)}
              end
            end)

          case Task.yield(task, timeout_ms) || Task.shutdown(task) do
            {:ok, result} -> result
            nil -> {false, "Health check timed out"}
          end
        rescue
          error -> {false, inspect(error)}
        end
    end
  end

  # Fast version that only checks local state - NO HTTP calls
  # Used during mount to avoid blocking page load
  # Returns map with: status (:running, :stopped, :loading, :none, :unknown), endpoint, instance_id
  defp check_gpu_instance_status_fast do
    if Process.whereis(InstanceManager) do
      try do
        # Use the new status() function that returns full state
        status_map = InstanceManager.status()

        # Normalize status values for backward compatibility
        normalized_status =
          case status_map.status do
            :running -> :running
            :stopped -> :stopped
            :loading -> :loading
            :none -> :no_instance
            _ -> :unknown
          end

        %{
          status: normalized_status,
          endpoint: status_map.endpoint,
          instance_id: status_map.instance_id
        }
      rescue
        _ -> %{status: :unknown, endpoint: nil, instance_id: nil}
      catch
        :exit, _ -> %{status: :unknown, endpoint: nil, instance_id: nil}
      end
    else
      %{status: :unknown, endpoint: nil, instance_id: nil}
    end
  end

  defp auto_provision_gpu do
    # SAFETY CHECK: Double-check for existing instances before starting
    # This is a second layer of protection in case the caller didn't check
    case InstanceManager.check_existing_instance() do
      {:ok, endpoint} when is_binary(endpoint) ->
        Logger.warning(
          "[auto_provision_gpu] Instance already exists at #{endpoint}, aborting provisioning"
        )

        {:error, :instance_already_exists}

      {:ok, :running, instance_id} ->
        Logger.warning(
          "[auto_provision_gpu] Found untracked instance #{instance_id}, aborting provisioning"
        )

        {:error, {:untracked_instance, instance_id}}

      {:ok, :none} ->
        # Safe to proceed
        do_auto_provision_gpu()

      {:error, reason} ->
        Logger.error(
          "[auto_provision_gpu] Failed to check existing instances: #{inspect(reason)}"
        )

        # Proceed with caution - let the provisioning try and fail if needed
        do_auto_provision_gpu()
    end
  end

  defp do_auto_provision_gpu do
    # Use shared ProvisioningState for real-time updates
    ProvisioningState.start_provisioning(true)
    ProvisioningState.add_log(:info, "=== GPU AUTO-PROVISIONING STARTED ===")
    ProvisioningState.add_log(:info, "Time: #{DateTime.utc_now() |> DateTime.to_string()}")

    # Check configuration upfront
    ProvisioningState.add_log(:info, "=== PRE-FLIGHT CONFIG CHECK ===")

    vast_api_key = System.get_env("VAST_API_KEY")
    cf_token = System.get_env("LUMAINUS_DOT_COM_CLOUDFLARE_API_TOKEN")
    cf_zone = System.get_env("LUMAINUS_DOT_COM_CLOUDFLARE_ZONE_ID")
    cf_fqdn = Cloudflare.cloud_fqdn()

    ProvisioningState.add_log(
      :info,
      "Vast.ai API Key: #{if vast_api_key, do: "#{String.slice(vast_api_key, 0, 8)}...", else: "NOT SET!"}"
    )

    ProvisioningState.add_log(
      :info,
      "Cloudflare Token: #{if cf_token, do: "#{String.slice(cf_token, 0, 8)}...", else: "NOT SET!"}"
    )

    ProvisioningState.add_log(
      :info,
      "Cloudflare Zone: #{if cf_zone, do: "#{String.slice(cf_zone, 0, 8)}...", else: "NOT SET!"}"
    )

    ProvisioningState.add_log(:info, "Cloudflare FQDN: #{cf_fqdn || "NOT SET!"}")

    if is_nil(vast_api_key) do
      ProvisioningState.add_log(:error, "VAST_API_KEY not set - cannot continue!")
      ProvisioningState.fail(:missing_vast_api_key)
      {:error, :missing_vast_api_key}
    else
      if is_nil(cf_token) or is_nil(cf_zone) do
        ProvisioningState.add_log(:warning, "Cloudflare not configured - will fall back to HTTP")
      end

      # Search for best offers with good defaults
      ProvisioningState.add_log(:info, "=== PHASE 1: Search GPU Offers ===")
      ProvisioningState.update_status("Searching for GPU offers...")

      filters =
        VastAIOffers.build_filters(
          gpu_name: "RTX 3090",
          num_gpus: 1,
          verified: true,
          rentable: true,
          geolocation: ["US", "CA"],
          dph_total: {:lte, 0.30},
          cpu_ram: {:gte, 16},
          cpu_cores: {:gte, 4},
          inet_down: {:gte, 100},
          disk_space: {:gte, 16}
        )

      ProvisioningState.add_log(
        :info,
        "Filter criteria: RTX 3090, 1 GPU, US/CA, <$0.30/hr, 16GB+ RAM"
      )

      case VastAIOffers.search(filters: filters, limit: 3) do
        {:ok, %{"offers" => []}} ->
          ProvisioningState.add_log(:error, "No GPU offers found matching requirements")
          ProvisioningState.fail(:no_offers)
          {:error, :no_offers}

        {:ok, %{"offers" => offers}} ->
          ProvisioningState.add_log(:success, "Found #{length(offers)} offers")

          for offer <- offers do
            ProvisioningState.add_log(
              :info,
              "  - Offer ##{offer["id"]}: $#{Float.round((offer["dph_total"] || 0) * 1.0, 3)}/hr, #{offer["gpu_name"]}, #{offer["geolocation"]}"
            )
          end

          # Try top offers in order with full HTTPS provisioning
          try_provision_offers_with_https(offers)

        {:error, reason} ->
          ProvisioningState.add_log(:error, "Failed to search offers: #{inspect(reason)}")
          ProvisioningState.fail(reason)
          {:error, reason}
      end
    end
  end

  defp try_provision_offers_with_https([]) do
    ProvisioningState.add_log(:error, "All offers failed to provision")
    ProvisioningState.fail(:all_offers_failed)
    {:error, :all_offers_failed}
  end

  defp try_provision_offers_with_https([offer | rest]) do
    offer_id = offer["id"]
    remaining = length(rest)

    ProvisioningState.add_log(:info, "=== Trying offer ##{offer_id} (#{remaining} remaining) ===")

    ProvisioningState.add_log(
      :info,
      "  Price: $#{Float.round((offer["dph_total"] || 0) * 1.0, 3)}/hr"
    )

    ProvisioningState.add_log(
      :info,
      "  GPU: #{offer["gpu_name"]} (#{div(offer["gpu_ram"] || 0, 1024)}GB VRAM)"
    )

    ProvisioningState.add_log(:info, "  Location: #{offer["geolocation"]}")

    ProvisioningState.add_log(
      :info,
      "  Reliability: #{Float.round((offer["reliability"] || 0) * 100, 0)}%"
    )

    ProvisioningState.update_status("Creating instance from offer ##{offer_id}...")

    # Generate the Caddy onstart script that starts uvicorn and sets up HTTPS
    onstart = VastAI.caddy_onstart_script(Cloudflare.cloud_fqdn(), VastAI.cloud_port())

    ProvisioningState.add_log(
      :info,
      "Calling VastAI.provision(offer_id: #{offer_id}, disk_gb: 20, label: lumainus-docling, onstart: <script>)"
    )

    case VastAI.provision(
           offer_id: offer_id,
           disk_gb: 20,
           label: "lumainus-docling",
           onstart: onstart
         ) do
      {:ok, instance_id} ->
        ProvisioningState.add_log(:success, "=== PHASE 1 COMPLETE ===")

        ProvisioningState.add_log(
          :success,
          "Instance ##{instance_id} created from offer ##{offer_id}"
        )

        # Continue with full HTTPS setup
        finish_https_provisioning(instance_id)

      {:error, reason} ->
        ProvisioningState.add_log(:error, "Offer ##{offer_id} failed: #{inspect(reason)}")

        if rest != [] do
          ProvisioningState.add_log(:info, "Trying next offer (#{remaining} remaining)...")
          try_provision_offers_with_https(rest)
        else
          ProvisioningState.add_log(
            :error,
            "All #{length([offer | rest])} offers exhausted - provisioning failed"
          )

          ProvisioningState.fail(reason)
          {:error, reason}
        end
    end
  end

  defp finish_https_provisioning(instance_id) do
    ProvisioningState.add_log(:info, "=== PHASE 2: Wait for instance boot ===")
    ProvisioningState.add_log(:info, "Instance ID: #{instance_id}")
    ProvisioningState.add_log(:info, "Timeout: 5 minutes (300 seconds)")
    ProvisioningState.update_status("Instance ##{instance_id} created, waiting for boot...")

    # Use granular wait with status updates
    case wait_for_ready_with_logging(instance_id, 300_000) do
      {:ok, instance} ->
        ProvisioningState.add_log(:success, "=== PHASE 2 COMPLETE: Instance is running! ===")

        # Log all instance details
        ProvisioningState.add_log(:info, "Instance details:")
        ProvisioningState.add_log(:info, "  - actual_status: #{instance["actual_status"]}")

        ProvisioningState.add_log(
          :info,
          "  - public_ipaddr: #{instance["public_ipaddr"] || "NONE"}"
        )

        ProvisioningState.add_log(:info, "  - ssh_host: #{instance["ssh_host"] || "NONE"}")
        ProvisioningState.add_log(:info, "  - ssh_port: #{instance["ssh_port"] || "NONE"}")
        ProvisioningState.add_log(:info, "  - gpu_name: #{instance["gpu_name"] || "?"}")
        ProvisioningState.add_log(:info, "  - label: #{instance["label"] || "?"}")

        ProvisioningState.add_log(:info, "=== PHASE 3: Setup DNS ===")
        ProvisioningState.update_status("Instance running, setting up DNS...")

        case instance["public_ipaddr"] do
          ip when is_binary(ip) and ip != "" ->
            ProvisioningState.add_log(:info, "Public IP obtained: #{ip}")
            setup_dns_and_ssl(instance_id, ip, instance)

          nil ->
            ProvisioningState.add_log(:error, "public_ipaddr is nil!")

            ProvisioningState.add_log(
              :error,
              "Full instance data: #{inspect(instance, limit: 1000)}"
            )

            ProvisioningState.fail(:no_public_ip)
            {:error, :no_public_ip}

          "" ->
            ProvisioningState.add_log(:error, "public_ipaddr is empty string!")
            ProvisioningState.fail(:no_public_ip)
            {:error, :no_public_ip}

          other ->
            ProvisioningState.add_log(:error, "Unexpected public_ipaddr value: #{inspect(other)}")
            ProvisioningState.fail(:no_public_ip)
            {:error, :no_public_ip}
        end

      {:error, :timeout} ->
        ProvisioningState.add_log(:error, "=== PHASE 2 FAILED: Timeout ===")

        ProvisioningState.add_log(
          :error,
          "Instance did not reach 'running' state within 5 minutes"
        )

        ProvisioningState.add_log(:info, "Tip: Check Vast.ai console for instance status")
        ProvisioningState.fail(:timeout)
        {:error, :timeout}

      {:error, :exited} ->
        ProvisioningState.add_log(:error, "=== PHASE 2 FAILED: Instance exited ===")
        ProvisioningState.add_log(:error, "Instance crashed or was terminated")
        ProvisioningState.fail(:exited)
        {:error, :exited}

      {:error, reason} ->
        ProvisioningState.add_log(:error, "=== PHASE 2 FAILED: #{inspect(reason)} ===")
        ProvisioningState.fail(reason)
        {:error, reason}
    end
  end

  defp setup_dns_and_ssl(instance_id, ip, instance) do
    ProvisioningState.add_log(:info, "Checking Cloudflare configuration...")

    # Log Cloudflare config
    fqdn = Cloudflare.cloud_fqdn()
    zone_id = System.get_env("LUMAINUS_DOT_COM_CLOUDFLARE_ZONE_ID")
    token = System.get_env("LUMAINUS_DOT_COM_CLOUDFLARE_API_TOKEN")

    missing_cloudflare? =
      String.trim(fqdn) == "" or zone_id in [nil, ""] or token in [nil, ""]

    ProvisioningState.add_log(:info, "  - Target FQDN: #{fqdn || "NOT SET"}")

    ProvisioningState.add_log(
      :info,
      "  - Zone ID: #{if zone_id, do: "#{String.slice(zone_id, 0, 8)}...", else: "NOT SET"}"
    )

    ProvisioningState.add_log(
      :info,
      "  - API Token: #{if token, do: "#{String.slice(token, 0, 8)}...", else: "NOT SET"}"
    )

    if missing_cloudflare? do
      ProvisioningState.add_log(:error, "Cloudflare not fully configured!")
      fallback_to_http(instance_id, ip)
    else
      ProvisioningState.add_log(:info, "Calling Cloudflare.update_dns_record(#{ip})...")
      ProvisioningState.update_status("Updating Cloudflare DNS: #{fqdn} -> #{ip}")

      case Cloudflare.update_dns_record(ip) do
        {:ok, dns_result} ->
          ProvisioningState.add_log(:success, "=== PHASE 3 COMPLETE: DNS updated ===")
          ProvisioningState.add_log(:info, "DNS Result: #{inspect(dns_result)}")

          endpoint = "https://#{dns_result.fqdn}"
          ProvisioningState.add_log(:info, "=== PHASE 4: SSL/HTTPS Setup ===")
          ProvisioningState.add_log(:info, "HTTPS endpoint: #{endpoint}")

          ProvisioningState.add_log(
            :info,
            "Caddy will obtain Let's Encrypt cert on first request"
          )

          # Wait for the service to be ready (Docker pull + service start)
          ProvisioningState.add_log(:info, "=== PHASE 4: Wait for service ready ===")
          ProvisioningState.add_log(:info, "Waiting for Docker image pull and service start...")

          http_url = "http://#{ip}:#{VastAI.cloud_port()}/health"

          case wait_for_service_health(http_url, 300_000) do
            :ok ->
              ProvisioningState.add_log(:success, "Service is responding!")

              # Now test HTTPS via Caddy
              ProvisioningState.add_log(:info, "Testing HTTPS endpoint...")
              https_url = "#{endpoint}/health"
              test_endpoint(https_url, "HTTPS via Caddy")

            {:error, :timeout} ->
              ProvisioningState.add_log(
                :warning,
                "Service not responding yet - may still be starting"
              )

              ProvisioningState.add_log(
                :info,
                "Continuing anyway - health checks will retry on /reports"
              )
          end

          # Save the cloud URL
          ProvisioningState.add_log(:info, "Saving cloud URL to settings: #{endpoint}")

          case DoclingSettings.update_cloud_url(endpoint) do
            {:ok, _} ->
              ProvisioningState.add_log(:success, "Cloud URL saved!")

            {:error, err} ->
              ProvisioningState.add_log(:warning, "Failed to save URL: #{inspect(err)}")
          end

          # CRITICAL: Update InstanceManager so it knows about this instance
          # This prevents duplicate provisioning when cloud backend is used
          ProvisioningState.add_log(:info, "Registering instance with InstanceManager...")
          InstanceManager.set_endpoint(instance_id, endpoint, ip)
          ProvisioningState.add_log(:success, "Instance registered with InstanceManager")

          ProvisioningState.add_log(:success, "=== PROVISIONING COMPLETE ===")
          ProvisioningState.add_log(:info, "Instance: ##{instance_id}")
          ProvisioningState.add_log(:info, "Endpoint: #{endpoint}")

          ProvisioningState.add_log(
            :info,
            "SSH: ssh -p #{instance["ssh_port"]} root@#{instance["ssh_host"]}"
          )

          ProvisioningState.complete(instance_id, endpoint)
          {:ok, instance_id}

        {:error, dns_error} ->
          ProvisioningState.add_log(:error, "=== PHASE 3 FAILED: DNS update error ===")
          ProvisioningState.add_log(:error, "Error: #{inspect(dns_error)}")
          fallback_to_http(instance_id, ip)
      end
    end
  end

  defp fallback_to_http(instance_id, ip) do
    endpoint = "http://#{ip}:#{VastAI.cloud_port()}"
    ProvisioningState.add_log(:warning, "Falling back to HTTP (no SSL)")
    ProvisioningState.add_log(:info, "HTTP endpoint: #{endpoint}")

    # Test HTTP endpoint
    test_endpoint("#{endpoint}/health", "HTTP direct")

    DoclingSettings.update_cloud_url(endpoint)

    # CRITICAL: Update InstanceManager so it knows about this instance
    # This prevents duplicate provisioning when cloud backend is used
    ProvisioningState.add_log(:info, "Registering instance with InstanceManager...")
    InstanceManager.set_endpoint(instance_id, endpoint, ip)
    ProvisioningState.add_log(:success, "Instance registered with InstanceManager")

    ProvisioningState.complete(instance_id, endpoint)
    {:ok, instance_id}
  end

  defp test_endpoint(url, label) do
    ProvisioningState.add_log(:info, "  Testing #{label}: #{url}")

    case Req.get(url, receive_timeout: 15_000, retry: false) do
      {:ok, %{status: status, body: body}} ->
        ProvisioningState.add_log(:success, "  #{label}: HTTP #{status}")

        if is_map(body) do
          ProvisioningState.add_log(:info, "  Response: #{inspect(body, limit: 200)}")
        end

      {:error, %{reason: reason}} ->
        ProvisioningState.add_log(:warning, "  #{label}: Failed - #{inspect(reason)}")

      {:error, reason} ->
        ProvisioningState.add_log(:warning, "  #{label}: Failed - #{inspect(reason)}")
    end
  end

  # Wait for service health endpoint to respond (handles Docker pull time)
  defp wait_for_service_health(url, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    # 10 seconds between checks
    poll_interval = 10_000

    do_health_wait_loop(url, deadline, poll_interval, 0)
  end

  defp do_health_wait_loop(url, deadline, poll_interval, attempt) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      if rem(attempt, 3) == 0 do
        ProvisioningState.add_log(:info, "Health check attempt #{attempt + 1}...")
      end

      case Req.get(url, receive_timeout: 10_000, retry: false) do
        {:ok, %{status: status}} when status in 200..299 ->
          ProvisioningState.add_log(:success, "Health check passed on attempt #{attempt + 1}")
          :ok

        {:ok, %{status: status}} ->
          ProvisioningState.add_log(:info, "Health check returned #{status}, retrying...")
          Process.sleep(poll_interval)
          do_health_wait_loop(url, deadline, poll_interval, attempt + 1)

        {:error, _reason} ->
          # Service not ready yet - this is expected during Docker pull
          Process.sleep(poll_interval)
          do_health_wait_loop(url, deadline, poll_interval, attempt + 1)
      end
    end
  end

  # Wait for instance with detailed logging
  defp wait_for_ready_with_logging(instance_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    # 10 seconds between polls
    poll_interval = 10_000
    last_status = nil

    do_wait_loop(instance_id, deadline, poll_interval, last_status, 0)
  end

  defp do_wait_loop(instance_id, deadline, poll_interval, last_status, poll_count) do
    if System.monotonic_time(:millisecond) >= deadline do
      ProvisioningState.add_log(:error, "Timeout waiting for instance after #{poll_count} polls")
      {:error, :timeout}
    else
      result = VastAIInstances.get(instance_id)

      # Log raw response on first poll for debugging
      if poll_count == 0 do
        ProvisioningState.add_log(:info, "Raw API response: #{inspect(result, limit: 500)}")
      end

      case result do
        {:ok, response} when is_map(response) ->
          # Extract instance data - API returns %{"instances" => %{data}} (map, not list!)
          instance_data =
            case response do
              # Map with id key
              %{"instances" => %{"id" => _} = inst} ->
                inst

              # List format
              %{"instances" => [inst | _]} ->
                inst

              # Single instance
              %{"instance" => inst} ->
                inst

              # Direct instance data
              %{"id" => _} = inst ->
                inst

              _ ->
                ProvisioningState.add_log(
                  :warning,
                  "Could not extract instance data from: #{inspect(response, limit: 300)}"
                )

                nil
            end

          if is_nil(instance_data) do
            Process.sleep(poll_interval)
            do_wait_loop(instance_id, deadline, poll_interval, last_status, poll_count + 1)
          else
            # Check BOTH actual_status AND cur_state - API uses both inconsistently
            actual_status = instance_data["actual_status"]
            cur_state = instance_data["cur_state"]
            # Use cur_state as fallback
            status = actual_status || cur_state
            status_msg = instance_data["status_msg"]
            ssh_host = instance_data["ssh_host"]
            public_ip = instance_data["public_ipaddr"]
            intended_status = instance_data["intended_status"]
            label = instance_data["label"]

            # Log status changes
            status_key = {actual_status, cur_state, status_msg}

            if status_key != last_status do
              ProvisioningState.add_log(
                :info,
                "Poll ##{poll_count}: actual=#{actual_status || "nil"} | cur=#{cur_state || "nil"} | intended=#{intended_status || "?"}"
              )

              if label, do: ProvisioningState.add_log(:info, "Label: #{label}")

              if status_msg && status_msg != "",
                do: ProvisioningState.add_log(:info, "Msg: #{status_msg}")

              if ssh_host,
                do:
                  ProvisioningState.add_log(
                    :info,
                    "SSH: #{ssh_host}:#{instance_data["ssh_port"]}"
                  )

              if public_ip && public_ip != "",
                do: ProvisioningState.add_log(:info, "IP: #{public_ip}")
            end

            ProvisioningState.update_status(
              "Instance ##{instance_id}: #{status || "pending"}... (#{poll_count * 10}s)"
            )

            # Check if running - use EITHER actual_status OR cur_state
            cond do
              actual_status == "running" or cur_state == "running" ->
                ProvisioningState.add_log(
                  :success,
                  "Instance is running! (actual=#{actual_status}, cur=#{cur_state})"
                )

                {:ok, instance_data}

              actual_status == "exited" or cur_state == "exited" ->
                ProvisioningState.add_log(:error, "Instance exited unexpectedly")
                ProvisioningState.add_log(:error, "Status msg: #{status_msg}")
                {:error, :exited}

              true ->
                Process.sleep(poll_interval)
                do_wait_loop(instance_id, deadline, poll_interval, status_key, poll_count + 1)
            end
          end

        {:ok, other} ->
          ProvisioningState.add_log(
            :warning,
            "Unexpected response type: #{inspect(other, limit: 200)}"
          )

          Process.sleep(poll_interval)
          do_wait_loop(instance_id, deadline, poll_interval, last_status, poll_count + 1)

        {:error, reason} = error ->
          ProvisioningState.add_log(:error, "API error: #{inspect(reason)}")
          error
      end
    end
  end

  defp maybe_fast_cost_flash(socket, :cloud) do
    put_flash(socket, :info, "Cloud (GPU) uses remote GPUs and may incur cost.")
  end

  defp maybe_fast_cost_flash(socket, _), do: socket

  defp format_backend_reason(nil), do: nil

  defp format_backend_reason(reason) when is_binary(reason) do
    # Return user-friendly messages for common reasons
    cond do
      String.contains?(reason, "Service starting") ->
        # Already user-friendly
        reason

      String.contains?(reason, "GPU instance still loading") ->
        reason

      String.contains?(reason, "No GPU instance") ->
        reason

      String.contains?(reason, "not configured") ->
        reason

      String.contains?(reason, "timeout") ->
        "connection timed out"

      String.contains?(reason, "econnrefused") ->
        "service not responding"

      String.contains?(reason, "nxdomain") ->
        "hostname not found"

      String.contains?(reason, "transport_error") ->
        "network error"

      true ->
        # Truncate long technical messages
        if String.length(reason) > 50 do
          String.slice(reason, 0, 47) <> "..."
        else
          reason
        end
    end
  end

  defp format_backend_reason(reason), do: inspect(reason)

  defp backend_label(backend) do
    case normalize_backend_atom(backend) do
      :cloud -> "Cloud (GPU)"
      _ -> "Local"
    end
  end

  defp backend_badge_class(backend, status \\ nil) do
    base_class =
      case normalize_backend_atom(backend) do
        :cloud -> "bg-sky-100 text-sky-700 border border-sky-200"
        _ -> "bg-slate-100 text-slate-700 border border-slate-200"
      end

    if status == "fallback_to_local" do
      base_class <> " opacity-70"
    else
      base_class
    end
  end

  defp backend_badge_title("fallback_to_local"), do: "Fast unavailable; fell back to Standard"
  defp backend_badge_title(_), do: "Docling backend"

  defp normalize_backend_atom(nil), do: :local

  defp normalize_backend_atom(value) do
    Docling.normalize_user_backend(value)
  rescue
    _ -> :local
  end

  defp update_document_progress(documents, payload) do
    upload_id = Map.get(payload, :upload_id) || Map.get(payload, "upload_id")
    stage = Map.get(payload, :stage) || Map.get(payload, "stage")
    progress = Map.get(payload, :progress) || Map.get(payload, "progress")
    state = Map.get(payload, :state) || Map.get(payload, "state")
    message = Map.get(payload, :last_message) || Map.get(payload, "last_message")
    last_error = Map.get(payload, :last_error) || Map.get(payload, "last_error")
    job_id = Map.get(payload, :job_id) || Map.get(payload, "job_id")
    timeout_at = Map.get(payload, :timeout_at) || Map.get(payload, "timeout_at")
    event = Map.get(payload, :event) || Map.get(payload, "event") || %{}
    progress_payload = Map.get(event, :payload) || Map.get(event, "payload")

    backend =
      Map.get(payload, :backend) ||
        Map.get(payload, "backend") ||
        Map.get(progress_payload || %{}, :backend) ||
        Map.get(progress_payload || %{}, "backend")

    backend_status =
      Map.get(payload, :backend_status) ||
        Map.get(payload, "backend_status") ||
        Map.get(progress_payload || %{}, :backend_status) ||
        Map.get(progress_payload || %{}, "backend_status")

    Enum.map(documents, fn doc ->
      if doc.id == upload_id do
        doc
        |> Map.put(:status, state || stage || doc.status)
        |> Map.put(:ingestion_state, state || doc.ingestion_state)
        |> Map.put(:ingestion_stage, stage || doc.ingestion_stage)
        |> Map.put(:ingestion_progress, progress || doc.ingestion_progress)
        |> Map.put(:ingestion_message, message || doc.ingestion_message)
        |> Map.put(:ingestion_error, last_error || doc.ingestion_error)
        |> Map.put(:ingestion_job_id, job_id || doc.ingestion_job_id)
        |> Map.put(:ingestion_timeout_at, timeout_at || doc.ingestion_timeout_at)
        |> Map.put(:backend, backend || doc.backend)
        |> Map.put(:backend_status, backend_status || doc.backend_status)
        |> maybe_put_progress(progress_payload)
      else
        doc
      end
    end)
  end

  defp maybe_put_progress(doc, nil), do: doc

  defp maybe_put_progress(doc, payload) when is_map(payload) do
    # Convert atom keys to string keys for consistency with component
    progress = %{
      "overall" => payload[:overall] || payload["overall"] || doc.ingestion_progress,
      "stage" => payload[:stage] || payload["stage"],
      "stage_name" => payload[:stage_name] || payload["stage_name"],
      "stage_progress" => payload[:stage_progress] || payload["stage_progress"],
      "pages_done" => payload[:pages_done] || payload["pages_done"],
      "pages_total" => payload[:pages_total] || payload["pages_total"],
      "stages" => payload[:stages] || payload["stages"] || %{}
    }

    Map.put(doc, :progress, progress)
  end

  defp maybe_put_progress(doc, _), do: doc

  defp format_byte_size(nil), do: "—"

  defp format_byte_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_048_576 ->
        value = bytes / 1_048_576
        :erlang.float_to_binary(value, decimals: 1) <> " MB"

      bytes >= 1024 ->
        value = bytes / 1024
        :erlang.float_to_binary(value, decimals: 1) <> " KB"

      true ->
        Integer.to_string(bytes) <> " B"
    end
  end

  defp format_run(nil), do: nil

  defp format_run(run) do
    %{
      id: run.id,
      status: run.status,
      output_markdown: run.output_markdown,
      updated_at: run.updated_at,
      citations: Enum.map(run.citations || [], &format_citation/1)
    }
  end

  defp format_citation(citation) do
    %{
      id: citation.id,
      label: citation.citation_label,
      document_id: citation.document_id
    }
  end

  defp run_status(%{latest_run: nil}), do: "not_started"
  defp run_status(%{latest_run: %{status: status}}), do: status

  defp document_status(%{ingestion_state: state, ingestion_stage: stage, status: status}) do
    state || stage || status
  end

  defp document_status(_), do: nil

  defp docling_unreachable?(%{status: "unreachable"}), do: true
  defp docling_unreachable?(_), do: false

  # Show start button when instance exists but is stopped
  defp show_gpu_start_button?(gpu_status) do
    gpu_status.status == :stopped
  end

  # Show stop button when instance is running
  defp show_gpu_stop_button?(gpu_status) do
    gpu_status.status == :running
  end

  # Show "no instance" message when admin hasn't provisioned
  defp show_gpu_no_instance_message?(gpu_status, dismissed) do
    not dismissed and gpu_status.status == :no_instance
  end

  defp format_health_timestamp(nil), do: "no recent checks"

  defp format_health_timestamp(%{responded_at: %DateTime{} = dt}) do
    format_timestamp(dt)
  end

  defp format_health_timestamp(%{inserted_at: %DateTime{} = dt}) do
    format_timestamp(dt)
  end

  defp format_health_timestamp(_), do: "no recent checks"

  defp format_timeout_remaining(nil), do: "expired"

  defp format_timeout_remaining(%DateTime{} = dt) do
    diff = DateTime.diff(dt, DateTime.utc_now(), :second)
    format_timeout_diff(diff)
  end

  defp format_timeout_remaining(iso_string) when is_binary(iso_string) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(iso_string) do
      diff = DateTime.diff(datetime, DateTime.utc_now(), :second)
      format_timeout_diff(diff)
    else
      _ -> "—"
    end
  end

  defp format_timeout_remaining(_), do: "—"

  defp format_timeout_diff(diff) do
    cond do
      diff <= 0 ->
        "expired"

      diff < 60 ->
        "#{diff}s"

      diff < 3600 ->
        minutes = div(diff, 60)
        seconds = rem(diff, 60)
        "#{minutes}:#{String.pad_leading(Integer.to_string(seconds), 2, "0")}"

      true ->
        minutes = div(diff, 60)
        seconds = rem(diff, 60)
        "#{minutes}:#{String.pad_leading(Integer.to_string(seconds), 2, "0")}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      .reports-shell {
        min-height: calc(100vh - 96px);
        background: #f8fafc;
        padding: 32px;
        display: flex;
        flex-direction: column;
        gap: 24px;
      }

      .patient-banner {
        background: #fff;
        border: 1px solid #e2e8f0;
        border-radius: 16px;
        padding: 24px;
        display: flex;
        flex-wrap: wrap;
        gap: 16px;
        justify-content: space-between;
      }

      .patient-actions {
        display: flex;
        align-items: center;
        gap: 8px;
      }

      .patient-actions .manage-btn {
        border: 1px solid #cbd5e1;
        color: #0f172a;
        background: linear-gradient(135deg, #f8fbff, #eef4ff);
        border-radius: 999px;
        padding: 6px 16px;
        font-size: 12px;
        font-weight: 600;
        box-shadow: 0 4px 10px rgba(15, 23, 42, 0.08);
        transition: transform 0.2s ease, box-shadow 0.2s ease, background 0.2s ease;
      }

      .patient-actions .manage-btn:hover,
      .patient-actions .manage-btn:focus-visible {
        background: linear-gradient(135deg, #e0ecff, #f3f8ff);
        box-shadow: 0 6px 14px rgba(15, 23, 42, 0.12);
        transform: translateY(-1px);
      }

      .reports-body {
        display: grid;
        grid-template-columns: 320px 1fr;
        gap: 24px;
      }

      .documents-panel {
        background: #fff;
        border: 1px solid #e2e8f0;
        border-radius: 16px;
        padding: 16px;
        display: flex;
        flex-direction: column;
        gap: 12px;
        height: calc(100vh - 240px);
      }

      .document-list {
        flex: 1;
        overflow-y: auto;
        padding-right: 4px;
        display: flex;
        flex-direction: column;
        gap: 8px;
      }

      .document-card {
        border: 1px solid #e2e8f0;
        border-radius: 12px;
        padding: 12px;
        text-align: left;
        transition: border-color 0.2s ease;
        background: #fff;
      }

      .document-card.active {
        border-color: #2563eb;
        background: #f8fbff;
      }

      .doc-detail-meta {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
        gap: 12px;
        margin-top: 12px;
        font-size: 11px;
        color: #475569;
      }

      .doc-detail-meta strong {
        display: block;
        font-size: 13px;
        color: #0f172a;
      }

      .doc-detail-actions {
        display: flex;
        gap: 6px;
        align-items: center;
        flex-wrap: wrap;
        justify-content: flex-end;
      }

      .modal-backdrop {
        position: fixed;
        inset: 0;
        background: rgba(15, 23, 42, 0.45);
        display: flex;
        align-items: center;
        justify-content: center;
        z-index: 50;
      }

      .patient-modal {
        width: min(960px, 95vw);
        background: #fff;
        border-radius: 16px;
        padding: 24px;
        border: 1px solid #e2e8f0;
        box-shadow: 0 20px 40px rgba(15, 23, 42, 0.25);
        display: flex;
        flex-direction: column;
        gap: 16px;
        color: #0f172a;
      }

      .document-modal {
        width: min(1100px, 96vw);
        max-height: 85vh;
        background: #fff;
        border-radius: 24px;
        padding: 32px;
        border: 1px solid #e2e8f0;
        box-shadow: 0 30px 60px rgba(15, 23, 42, 0.35);
        display: flex;
        flex-direction: column;
        gap: 20px;
        color: #0f172a;
      }

      .document-modal-header {
        display: flex;
        justify-content: space-between;
        align-items: flex-start;
        gap: 24px;
      }

      .document-modal-header h2 {
        margin: 4px 0 0 0;
        font-size: 24px;
        font-weight: 600;
        color: #0f172a;
      }

      .document-meta {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
        gap: 16px;
        font-size: 12px;
        color: #64748b;
      }

      .document-meta span {
        text-transform: uppercase;
        letter-spacing: 0.08em;
        font-weight: 600;
        display: block;
        margin-bottom: 4px;
        color: #94a3b8;
      }

      .document-meta strong {
        display: block;
        font-size: 13px;
        color: #0f172a;
      }

      .document-modal-tabs {
        display: inline-flex;
        border-radius: 999px;
        border: 1px solid #e2e8f0;
        padding: 4px;
        gap: 4px;
        background: #f8fafc;
        align-self: flex-start;
      }

      .document-tab {
        border: none;
        border-radius: 999px;
        padding: 6px 18px;
        font-size: 13px;
        background: transparent;
        cursor: pointer;
        color: #475569;
        transition: background 160ms ease, color 160ms ease;
      }

      .document-tab.active {
        background: #1d4ed8;
        color: #fff;
        box-shadow: 0 6px 16px rgba(37, 99, 235, 0.35);
      }

      .document-modal-content {
        border: 1px solid #e2e8f0;
        border-radius: 16px;
        padding: 18px;
        background: #fdfefe;
        flex: 1;
        min-height: 260px;
        max-height: 100%;
        overflow-y: auto;
        font-size: 14px;
        line-height: 1.6;
        color: #0f172a;
      }

      .document-modal-content pre {
        white-space: pre-wrap;
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono",
          "Courier New", monospace;
        font-size: 13px;
        margin: 0;
      }

      .patient-modal .input,
      .patient-modal .textarea,
      .patient-modal .select {
        background: #fff !important;
        color: #0f172a;
        border-color: #e2e8f0;
      }

      .patient-modal .input::placeholder,
      .patient-modal .textarea::placeholder {
        color: #94a3b8;
      }

      .patient-modal .label {
        color: #475569;
        font-weight: 600;
      }

      .patient-modal-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
        gap: 20px;
      }

      .modal-column {
        display: flex;
        flex-direction: column;
        gap: 16px;
      }

      .modal-panel {
        border: 1px solid #e2e8f0;
        border-radius: 14px;
        padding: 16px;
        background: #fdfefe;
        display: flex;
        flex-direction: column;
        gap: 12px;
      }

      .modal-panel h3 {
        margin: 0;
        font-size: 13px;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        color: #94a3b8;
      }

      .recent-runs {
        display: flex;
        flex-direction: column;
        gap: 8px;
      }

      .recent-run {
        border: 1px solid #e2e8f0;
        border-radius: 12px;
        padding: 12px;
        background: #fff;
      }

      .recent-run header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        font-size: 13px;
        color: #0f172a;
      }

      .recent-run p {
        margin: 4px 0 0 0;
        font-size: 12px;
        color: #64748b;
      }

      .status-pill {
        font-size: 11px;
        padding: 2px 10px;
        border-radius: 999px;
        border: 1px solid #cbd5f5;
        background: #eff6ff;
        color: #1d4ed8;
      }

      .status-pill[data-status="running"] {
        border-color: #fde68a;
        background: #fffbeb;
        color: #b45309;
      }

      .status-pill[data-status="error"] {
        border-color: #fecdd3;
        background: #fef2f2;
        color: #b91c1c;
      }

      .prompt-summary {
        display: flex;
        flex-direction: column;
        gap: 12px;
      }

      .prompt-snippet {
        border: 1px dashed #e2e8f0;
        border-radius: 12px;
        padding: 12px;
        font-size: 12px;
        color: #475569;
        background: #fff;
      }

      .prompt-section-list {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
      }

      .prompt-section-list span {
        font-size: 12px;
        padding: 4px 10px;
        border-radius: 999px;
        background: #e0e7ff;
        color: #3730a3;
      }

      .workspace-list {
        display: flex;
        flex-direction: column;
        gap: 8px;
        max-height: 280px;
        overflow-y: auto;
      }

      .workspace-item {
        border: 1px solid #e2e8f0;
        border-radius: 12px;
        padding: 12px;
        text-align: left;
        background: #fff;
        color: #0f172a;
      }

      .workspace-item span,
      .workspace-item div:nth-child(2) {
        color: #475569;
      }

      .workspace-item small,
      .workspace-item .workspace-meta {
        color: #94a3b8;
      }

      .workspace-item.active {
        border-color: #2563eb;
        background: #f8fbff;
      }

      .workspace-run-meta {
        display: flex;
        justify-content: space-between;
        font-size: 11px;
        color: #94a3b8;
        margin-top: 6px;
        gap: 8px;
      }

      .section-card {
        border: 1px solid #e2e8f0;
        border-radius: 16px;
        padding: 20px;
        background: #fff;
        display: flex;
        flex-direction: column;
        gap: 12px;
      }

      .section-card[data-status="running"] {
        border-color: #3b82f6;
        box-shadow: 0 0 0 1px rgba(59, 130, 246, 0.2);
      }

      .section-card[data-status="error"] {
        border-color: #f97316;
      }

      .section-grid {
        display: flex;
        flex-direction: column;
        gap: 16px;
      }

      .section-actions {
        display: flex;
        gap: 8px;
        align-items: center;
      }

      .section-output {
        border: 1px solid #e2e8f0;
        border-radius: 12px;
        padding: 16px;
        background: #fdfefe;
        min-height: 140px;
        font-size: 14px;
        line-height: 1.5;
      }

      .markdown-body {
        line-height: 1.7;
        color: #0f172a;
      }

      .markdown-body h1,
      .markdown-body h2,
      .markdown-body h3,
      .markdown-body h4 {
        margin: 1.25rem 0 0.5rem;
        font-weight: 600;
      }

      .markdown-body p {
        margin: 0.75rem 0;
      }

      .markdown-body ul {
        list-style: disc;
        margin: 0.5rem 0 0.5rem 1.25rem;
      }

      .markdown-body li {
        margin-bottom: 0.35rem;
      }

      .markdown-body strong {
        color: #0f172a;
      }

      .report-markdown {
        font-size: 14px;
      }

      .provenance-link {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        border-radius: 999px;
        border: 1px solid #c7d2fe;
        background: #edf2ff;
        color: #3730a3;
        padding: 2px 12px;
        font-size: 12px;
        font-weight: 500;
        cursor: pointer;
        transition: background 160ms ease, color 160ms ease, box-shadow 160ms ease, transform 100ms ease;
        margin: 0 4px;
        white-space: nowrap;
      }

      .provenance-link:hover,
      .provenance-link:focus {
        background: #e0e7ff;
        color: #312e81;
        box-shadow: 0 0 0 3px rgba(99, 102, 241, 0.15);
        outline: none;
        transform: translateY(-1px);
      }

      .provenance-link:active {
        transform: translateY(0);
      }

      .citations {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
        font-size: 12px;
        color: #475569;
      }

      .citations button {
        border-radius: 999px;
        border: 1px solid #c7d2fe;
        background: #edf2ff;
        color: #3730a3;
        padding: 2px 14px;
        font-weight: 500;
        cursor: pointer;
        transition: background 160ms ease, color 160ms ease, box-shadow 160ms ease;
      }

      .citations button:hover,
      .citations button:focus {
        background: #e0e7ff;
        color: #312e81;
        box-shadow: 0 0 0 3px rgba(99, 102, 241, 0.15);
        outline: none;
      }

      .citations button:disabled {
        opacity: 0.5;
        cursor: not-allowed;
        box-shadow: none;
      }

      .citations span {
        background: #f1f5f9;
        border-radius: 999px;
        padding: 2px 10px;
      }

      @media (max-width: 1024px) {
        .reports-body {
          grid-template-columns: 1fr;
        }

        .documents-panel {
          height: auto;
        }
      }
    </style>

    <div class="reports-shell">
      <%= if docling_unreachable?(@docling_health) do %>
        <div class="rounded-xl border border-amber-200 bg-amber-50 text-amber-900 px-4 py-3 flex items-start justify-between gap-4">
          <div class="flex flex-col gap-1">
            <span class="text-sm font-semibold">Docling ingestion is unreachable</span>
            <span class="text-xs text-amber-800">
              Retries will stay queued until the service responds. Last check: {format_health_timestamp(
                @docling_health
              )}
            </span>
          </div>
          <span class="text-xs font-medium px-3 py-1 rounded-full bg-amber-100 border border-amber-200">
            Service down
          </span>
        </div>
      <% end %>

      <%!-- GPU Start Button (when instance is stopped) --%>
      <%= if @can_manage_gpu? and show_gpu_start_button?(@gpu_instance_status) do %>
        <div class="rounded-xl border border-amber-200 bg-gradient-to-r from-amber-50 to-orange-50 px-5 py-4 flex items-center justify-between gap-4 shadow-sm">
          <div class="flex items-center gap-4">
            <div class="flex h-12 w-12 items-center justify-center rounded-full bg-amber-100 text-amber-600">
              <svg
                class="h-6 w-6"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M5.25 5.653c0-.856.917-1.398 1.667-.986l11.54 6.347a1.125 1.125 0 0 1 0 1.972l-11.54 6.347a1.125 1.125 0 0 1-1.667-.986V5.653Z"
                />
              </svg>
            </div>
            <div class="flex flex-col">
              <span class="text-sm font-semibold text-gray-900">
                GPU Instance Stopped
              </span>
              <span class="text-xs text-gray-600">
                Start the GPU to enable fast document processing (~10x faster).
              </span>
            </div>
          </div>
          <button
            type="button"
            phx-click="start_gpu"
            class="rounded-full px-4 py-2 text-sm font-semibold text-white shadow-sm transition-colors bg-amber-600 hover:bg-amber-500"
          >
            Start GPU
          </button>
        </div>
      <% end %>

      <%!-- GPU Stop Button (when instance is running) --%>
      <%= if @can_manage_gpu? and show_gpu_stop_button?(@gpu_instance_status) do %>
        <div class="rounded-xl border border-green-200 bg-gradient-to-r from-green-50 to-emerald-50 px-5 py-4 flex items-center justify-between gap-4 shadow-sm">
          <div class="flex items-center gap-4">
            <div class="flex h-12 w-12 items-center justify-center rounded-full bg-green-100 text-green-600">
              <svg
                class="h-6 w-6"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M8.25 3v1.5M4.5 8.25H3m18 0h-1.5M4.5 12H3m18 0h-1.5m-15 3.75H3m18 0h-1.5M8.25 19.5V21M12 3v1.5m0 15V21m3.75-18v1.5m0 15V21m-9-1.5h10.5a2.25 2.25 0 002.25-2.25V6.75a2.25 2.25 0 00-2.25-2.25H6.75A2.25 2.25 0 004.5 6.75v10.5a2.25 2.25 0 002.25 2.25zm.75-12h9v9h-9v-9z"
                />
              </svg>
            </div>
            <div class="flex flex-col">
              <span class="text-sm font-semibold text-gray-900">
                GPU Instance Running
              </span>
              <span class="text-xs text-gray-600">
                Fast processing enabled. Stop when done to save costs.
              </span>
            </div>
          </div>
          <button
            type="button"
            phx-click="stop_gpu"
            class="rounded-full px-4 py-2 text-sm font-semibold text-white shadow-sm transition-colors bg-slate-600 hover:bg-slate-500"
          >
            Stop GPU
          </button>
        </div>
      <% end %>

      <%!-- No Instance Message (when admin hasn't provisioned) --%>
      <%= if @can_manage_gpu? and show_gpu_no_instance_message?(@gpu_instance_status, @gpu_prompt_dismissed) do %>
        <div class="rounded-xl border border-slate-200 bg-gradient-to-r from-slate-50 to-gray-50 px-5 py-4 flex items-center justify-between gap-4 shadow-sm">
          <div class="flex items-center gap-4">
            <div class="flex h-12 w-12 items-center justify-center rounded-full bg-slate-100 text-slate-500">
              <svg
                class="h-6 w-6"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M8.25 3v1.5M4.5 8.25H3m18 0h-1.5M4.5 12H3m18 0h-1.5m-15 3.75H3m18 0h-1.5M8.25 19.5V21M12 3v1.5m0 15V21m3.75-18v1.5m0 15V21m-9-1.5h10.5a2.25 2.25 0 002.25-2.25V6.75a2.25 2.25 0 00-2.25-2.25H6.75A2.25 2.25 0 004.5 6.75v10.5a2.25 2.25 0 002.25 2.25zm.75-12h9v9h-9v-9z"
                />
              </svg>
            </div>
            <div class="flex flex-col">
              <span class="text-sm font-semibold text-gray-900">
                No GPU Instance Available
              </span>
              <span class="text-xs text-gray-600">
                An administrator needs to provision a GPU instance first.
              </span>
            </div>
          </div>
          <button
            type="button"
            phx-click="dismiss_gpu_prompt"
            class="text-xs text-gray-500 hover:text-gray-700 px-3 py-1.5 rounded border border-slate-300 hover:border-slate-400"
          >
            Dismiss
          </button>
        </div>
      <% end %>

      <section class="patient-banner">
        <div>
          <div style="font-size: 12px; letter-spacing: 0.08em; text-transform: uppercase; color: #94a3b8; font-weight: 600;">
            Patient
          </div>
          <div style="font-size: 24px; font-weight: 600; color: #0f172a;">
            {patient_display_name(@patient)}
          </div>
          <div :if={patient_mrn(@patient) != "N/A"} style="font-size: 14px; color: #475569;">
            MRN {patient_mrn(@patient)}
          </div>
        </div>
        <div class="patient-actions">
          <form
            id="patient-switcher"
            phx-change="select_patient"
            class="flex items-center gap-2"
          >
            <label class="text-xs font-medium text-slate-600">
              Select patient
            </label>
            <select
              name="patient_id"
              class="select select-sm w-52 bg-white text-slate-900 border-slate-300"
            >
              <%= for patient <- @patients do %>
                <option value={patient.id} selected={patient.id == @patient.id}>
                  {patient_display_name(patient)}
                </option>
              <% end %>
            </select>
          </form>
          <button
            type="button"
            class="btn btn-outline btn-sm text-slate-700 border-slate-300 bg-slate-50 hover:bg-slate-100"
            phx-click="create_patient"
          >
            Add new patient
          </button>
          <button class="manage-btn" phx-click="open_patient_modal">
            Manage Workspace
          </button>
          <button
            class="btn btn-primary"
            phx-click="run_full_report"
            disabled={MapSet.size(@running_sections) > 0}
          >
            <%= if MapSet.size(@running_sections) > 0 do %>
              Running…
            <% else %>
              Run All Sections
            <% end %>
          </button>
        </div>
      </section>

      <div class="reports-body">
        <aside class="documents-panel">
          <div style="display: flex; justify-content: space-between; align-items: center;">
            <div style="font-size: 13px; font-weight: 600; color: #0f172a;">Source Documents</div>
            <div style="font-size: 12px; color: #94a3b8;">{length(@documents)} files</div>
          </div>
          <%= if @can_manage_gpu? do %>
            <div class="mt-1 rounded-lg border border-slate-200 bg-slate-50/70 p-3">
              <div class="flex items-center justify-between gap-3">
                <div class="flex flex-col">
                  <span class="text-[11px] uppercase tracking-[0.14em] text-slate-500">
                    Processing speed
                  </span>
                  <span class="text-sm text-slate-700">
                    Choose Standard (free) or Fast (GPU, $$)
                  </span>
                </div>
                <div class="flex items-center gap-2">
                  <button
                    type="button"
                    phx-click="set_docling_backend"
                    phx-value-backend="local"
                    class={[
                      "rounded-full border px-3 py-1 text-xs font-semibold transition",
                      @docling_backend == :local &&
                        "bg-slate-900 text-white border-slate-900 shadow-sm",
                      @docling_backend != :local &&
                        "bg-white text-slate-700 border-slate-200 hover:border-slate-300"
                    ]}
                  >
                    Standard
                  </button>
                  <button
                    type="button"
                    phx-click="set_docling_backend"
                    phx-value-backend="cloud"
                    disabled={!@fast_available?}
                    class={[
                      "rounded-full border px-3 py-1 text-xs font-semibold transition",
                      @docling_backend == :cloud &&
                        @fast_available? && "bg-sky-600 text-white border-sky-600 shadow-sm",
                      @docling_backend != :cloud &&
                        "bg-white text-slate-700 border-slate-200 hover:border-slate-300",
                      !@fast_available? && "opacity-60 cursor-not-allowed"
                    ]}
                  >
                    Fast (GPU)
                  </button>
                </div>
              </div>
              <div class="mt-2 flex flex-wrap items-center gap-2 text-xs text-slate-600">
                <span class={[
                  "inline-flex h-6 items-center rounded-full border px-2 font-semibold",
                  backend_badge_class(@docling_backend)
                ]}>
                  {backend_label(@docling_backend)}
                </span>
                <%= if @docling_backend == :cloud do %>
                  <span>Fast uses remote GPU processing and may incur cost.</span>
                <% else %>
                  <span>Standard uses the local CPU Docling service.</span>
                <% end %>
                <%= unless @fast_available? do %>
                  <span class={
                    if @fast_unavailable_reason &&
                         String.contains?(@fast_unavailable_reason || "", "Service starting"),
                       do: "text-sky-600",
                       else: "text-amber-600"
                  }>
                    <%= cond do %>
                      <% @fast_unavailable_reason && String.contains?(@fast_unavailable_reason, "Service starting") -> %>
                        {@fast_unavailable_reason}
                      <% @fast_unavailable_reason && String.contains?(@fast_unavailable_reason, "loading") -> %>
                        {@fast_unavailable_reason}
                      <% true -> %>
                        GPU service unavailable
                        <%= if @fast_unavailable_reason do %>
                          — {@fast_unavailable_reason}
                        <% end %>
                        — falling back to Standard.
                    <% end %>
                  </span>
                <% end %>
              </div>
            </div>
          <% end %>
          <form
            phx-change="noop"
            phx-submit="noop"
            phx-drop-target={@uploads.documents.ref}
            class="rounded-xl border border-dashed border-slate-300 p-4 flex flex-col gap-3 bg-slate-50"
          >
            <div class="text-sm text-slate-600">
              Drag & drop PDFs anywhere in this panel, or use Select PDFs to browse (up to 5 files, 25MB each). Uploads queue automatically once selected.
            </div>
            <div class="flex flex-col gap-2">
              <button
                type="button"
                class="flex w-full items-center gap-3 rounded-lg border border-slate-200 bg-white/90 px-3 py-3 text-left shadow-sm transition hover:border-slate-300 hover:bg-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-sky-500"
                phx-click={JS.dispatch("click", to: "##{@uploads.documents.ref}")}
              >
                <span
                  class="flex h-10 w-10 items-center justify-center rounded-full bg-slate-100 text-slate-500"
                  aria-hidden="true"
                >
                  <svg
                    class="h-5 w-5"
                    viewBox="0 0 20 20"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.5"
                  >
                    <path stroke-linecap="round" stroke-linejoin="round" d="M10 4.5v11m5.5-5.5h-11" />
                  </svg>
                </span>
                <span class="flex flex-col">
                  <span class="text-sm font-semibold text-slate-900">Select PDFs</span>
                  <span class="text-xs text-slate-500">Browse for medical reports to ingest</span>
                </span>
              </button>
              <button
                type="button"
                class="btn btn-outline btn-sm w-full text-slate-700 border-slate-300"
                phx-click="seed_sample_documents"
              >
                Load Sample Documents
              </button>
              <.live_file_input
                upload={@uploads.documents}
                class="hidden"
                aria-hidden="true"
              />
            </div>
            <%= for entry <- @uploads.documents.entries do %>
              <div class="text-xs text-slate-500 flex items-center gap-2">
                <span>{entry.client_name}</span>
                <span>{entry.progress}%</span>
              </div>
            <% end %>
            <input type="hidden" name="noop" value="" />
          </form>
          <div class="document-list">
            <%= for doc <- @documents do %>
              <button
                class={[
                  "document-card",
                  @selected_document && @selected_document.id == doc.id && "active"
                ]}
                phx-click="select_document"
                phx-value-doc-id={doc.id}
              >
                <div class="flex items-center justify-between text-xs uppercase tracking-[0.15em] text-slate-400">
                  <span>Doc {doc.sequence}</span>
                  <div class="flex items-center gap-2">
                    <span
                      class={[
                        "text-[10px] rounded-full px-2 py-0.5 normal-case tracking-normal border",
                        backend_badge_class(doc.backend, doc.backend_status)
                      ]}
                      title={backend_badge_title(doc.backend_status)}
                    >
                      {backend_label(doc.backend)}
                    </span>
                    <%= if status_label = document_status(doc) do %>
                      <span class="text-[10px] rounded-full border border-slate-200 px-2 py-0.5 normal-case tracking-normal">
                        {String.capitalize(status_label)}
                      </span>
                    <% end %>
                  </div>
                </div>
                <div style="font-size: 13px; font-weight: 600; color: #0f172a;">
                  {doc.label}
                </div>
                <div style="font-size: 11px; color: #94a3b8;">{doc.kind}</div>
                <div style="font-size: 12px; color: #475569; margin-top: 4px;">
                  {doc.summary}
                </div>
                <%= if doc.ingestion_stage && doc.ingestion_stage != "completed" do %>
                  <div style="margin-top: 8px;">
                    <%= if map_size(doc.progress) > 0 && doc.progress["stages"] && map_size(doc.progress["stages"]) > 0 do %>
                      <.progress_stages progress={doc.progress} compact={true} />
                    <% else %>
                      <div style="height: 6px; background: #e2e8f0; border-radius: 999px; overflow: hidden;">
                        <div style={"height: 6px; background: #3b82f6; border-radius: 999px; width: #{doc.ingestion_progress || 0}%; transition: width 200ms ease;"}>
                        </div>
                      </div>
                      <div style="display: flex; justify-content: space-between; font-size: 10px; color: #94a3b8; margin-top: 4px;">
                        <span>{String.capitalize(doc.ingestion_stage)}</span>
                        <span>{doc.ingestion_progress || 0}%</span>
                      </div>
                    <% end %>
                    <%= if doc.ingestion_message do %>
                      <div style="font-size: 11px; color: #94a3b8; margin-top: 4px;">
                        {doc.ingestion_message}
                      </div>
                    <% end %>
                    <%= if doc.ingestion_stage == "docling" && doc.ingestion_timeout_at do %>
                      <div style="font-size: 11px; color: #f59e0b; margin-top: 4px;">
                        Will timeout in
                        <span
                          id={"doc-timeout-#{doc.id}"}
                          phx-hook="IngestionCountdown"
                          data-deadline={doc.ingestion_timeout_at}
                        >
                          {format_timeout_remaining(doc.ingestion_timeout_at)}
                        </span>
                      </div>
                    <% end %>
                  </div>
                <% end %>
                <%= if doc.ingestion_error &&
                      (doc.ingestion_state == "failed" || doc.ingestion_stage == "failed") do %>
                  <div style="font-size: 11px; color: #b91c1c; margin-top: 6px;">
                    {doc.ingestion_error}
                  </div>
                <% end %>
                <div style="font-size: 11px; color: #94a3b8; margin-top: 6px;">
                  {doc.provider} · {doc.date}
                </div>
              </button>
            <% end %>
          </div>
          <%= if @selected_document do %>
            <div style="border-top: 1px solid #e2e8f0; padding-top: 12px; display: flex; flex-direction: column; gap: 8px;">
              <div style="display: flex; justify-content: space-between; align-items: center;">
                <div>
                  <div style="font-size: 11px; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.08em;">
                    Document {@selected_document.sequence}
                  </div>
                  <div style="font-size: 16px; font-weight: 600; color: #0f172a;">
                    {@selected_document.label}
                  </div>
                  <div style="font-size: 12px; color: #94a3b8;">
                    {@selected_document.filename}
                  </div>
                </div>
                <div class="doc-detail-actions">
                  <button class="btn btn-outline btn-xs text-slate-600" phx-click="clear_document">
                    Collapse
                  </button>
                  <%= if @selected_document.status in ["parsed", "completed"] do %>
                    <a
                      href={"/api/uploads/#{@selected_document.id}/download"}
                      download
                      class="btn btn-primary btn-xs"
                    >
                      Download MD
                    </a>
                  <% end %>
                  <%= if @selected_document.ingestion_state == "failed" do %>
                    <button
                      class="btn btn-primary btn-xs"
                      phx-click="retry_ingestion"
                      phx-value-doc-id={@selected_document.id}
                    >
                      Retry ingestion
                    </button>
                  <% end %>
                  <button
                    class="btn btn-error btn-xs"
                    phx-click="delete_document"
                    phx-value-doc-id={@selected_document.id}
                  >
                    Delete
                  </button>
                </div>
              </div>

              <div class="doc-detail-meta">
                <div>
                  <span>Uploaded</span>
                  <strong>{format_timestamp(@selected_document.uploaded_at)}</strong>
                </div>
                <div>
                  <span>File Size</span>
                  <strong>{@selected_document.byte_size_label}</strong>
                </div>
                <div>
                  <span>Status</span>
                  <strong>
                    {String.capitalize(document_status(@selected_document) || "pending")}
                  </strong>
                </div>
                <div>
                  <span>Backend</span>
                  <strong>
                    {backend_label(@selected_document.backend)}
                    <%= if @selected_document.backend_status == "fallback_to_local" do %>
                      <span class="text-amber-600 text-[11px] font-normal ml-1">(fallback)</span>
                    <% end %>
                  </strong>
                </div>
                <div>
                  <span>Type</span>
                  <strong>{@selected_document.content_type || "application/pdf"}</strong>
                </div>
                <%= if @selected_document.ingested_at do %>
                  <div>
                    <span>Processed</span>
                    <strong>{format_timestamp(@selected_document.ingested_at)}</strong>
                  </div>
                <% end %>
                <%= if @selected_document.ingestion_message do %>
                  <div>
                    <span>Stage</span>
                    <strong>{@selected_document.ingestion_message}</strong>
                  </div>
                <% end %>
                <%= if @selected_document.ingestion_error do %>
                  <div>
                    <span>Error</span>
                    <strong class="text-rose-600">
                      {@selected_document.ingestion_error}
                    </strong>
                  </div>
                <% end %>
                <%= if @selected_document.ingestion_stage == "docling" &&
                      @selected_document.ingestion_timeout_at do %>
                  <div>
                    <span>Timeout</span>
                    <strong>
                      Will timeout in
                      <span
                        id={"doc-timeout-detail-#{@selected_document.id}"}
                        phx-hook="IngestionCountdown"
                        data-deadline={@selected_document.ingestion_timeout_at}
                      >
                        {format_timeout_remaining(@selected_document.ingestion_timeout_at)}
                      </span>
                    </strong>
                  </div>
                <% end %>
              </div>

              <div style="font-size: 12px; color: #475569; white-space: pre-line; max-height: 200px; overflow-y: auto; border: 1px solid #e2e8f0; border-radius: 12px; padding: 12px; background: #fdfefe;">
                {@selected_document.cleaned_content ||
                  "This PDF is still being ingested. It will appear here when markdown is ready."}
              </div>
            </div>
          <% end %>
        </aside>

        <section class="section-grid">
          <%= for section_entry <- @sections do %>
            <article class="section-card" data-status={section_entry.status}>
              <header style="display: flex; justify-content: space-between; align-items: center;">
                <div>
                  <div style="font-size: 12px; text-transform: uppercase; color: #94a3b8; letter-spacing: 0.08em;">
                    Section
                  </div>
                  <div style="font-size: 18px; font-weight: 600; color: #0f172a;">
                    {section_entry.section.title}
                  </div>
                </div>
                <div class="section-actions">
                  <span style="font-size: 12px; color: #475569;">
                    {status_label(section_entry)}
                  </span>
                  <button
                    class={[
                      "btn btn-outline btn-sm border border-slate-300 text-slate-700 bg-white",
                      "hover:bg-slate-100 hover:text-slate-900 transition-colors"
                    ]}
                    phx-click="run_section"
                    phx-value-section-id={section_entry.section.id}
                    disabled={MapSet.member?(@running_sections, section_entry.section.id)}
                  >
                    <%= if MapSet.member?(@running_sections, section_entry.section.id) do %>
                      Running…
                    <% else %>
                      Run Section
                    <% end %>
                  </button>
                </div>
              </header>

              <div class="section-output">
                <%= if section_entry.last_run do %>
                  <div style="margin-bottom: 12px; font-size: 12px; color: #94a3b8;">
                    Updated {format_timestamp(section_entry.last_run.updated_at)}
                  </div>
                  <Markdown.markdown
                    content={section_entry.last_run.output_markdown}
                    fallback="Awaiting output"
                    class="report-markdown"
                  />
                <% else %>
                  <div style="font-size: 13px; color: #94a3b8;">
                    No output generated yet. Run this section to produce the initial draft.
                  </div>
                <% end %>
              </div>

              <%= if section_entry.last_run && Enum.any?(section_entry.last_run.citations) do %>
                <div class="citations">
                  <%= for citation <- section_entry.last_run.citations do %>
                    <%= if citation.document_id do %>
                      <button
                        type="button"
                        phx-click="open_document_modal"
                        phx-value-doc-id={citation.document_id}
                      >
                        {citation.label}
                      </button>
                    <% else %>
                      <span>{citation.label}</span>
                    <% end %>
                  <% end %>
                </div>
              <% end %>
            </article>
          <% end %>
        </section>
      </div>
    </div>

    <%= if @document_modal_open && @document_modal_document do %>
      <div class="modal-backdrop" phx-click="close_document_modal">
        <div class="document-modal" phx-click="noop">
          <header class="document-modal-header">
            <div>
              <div style="font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; color: #94a3b8;">
                Document {@document_modal_document.sequence}
              </div>
              <h2>{@document_modal_document.label}</h2>
              <div style="font-size: 13px; color: #64748b;">
                Uploaded {format_timestamp(@document_modal_document.uploaded_at)} • {@document_modal_document.filename}
              </div>
            </div>
            <div class="flex gap-2">
              <%= if @document_modal_document.status in ["parsed", "completed"] do %>
                <a
                  href={"/api/uploads/#{@document_modal_document.id}/download"}
                  download
                  class="btn btn-primary btn-sm"
                >
                  Download Markdown
                </a>
              <% end %>
              <button class="btn btn-ghost btn-sm" phx-click="close_document_modal">Close</button>
            </div>
          </header>

          <div class="document-meta">
            <div>
              <span>Provider</span>
              <strong>{@document_modal_document.provider}</strong>
            </div>
            <div>
              <span>Document kind</span>
              <strong>{@document_modal_document.kind}</strong>
            </div>
            <div>
              <span>Status</span>
              <strong>
                {String.capitalize(document_status(@document_modal_document) || "pending")}
              </strong>
            </div>
            <div>
              <span>File size</span>
              <strong>{@document_modal_document.byte_size_label}</strong>
            </div>
            <div>
              <span>Content type</span>
              <strong>{@document_modal_document.content_type || "application/pdf"}</strong>
            </div>
          </div>

          <div class="document-modal-tabs">
            <%= for tab <- document_modal_tabs() do %>
              <button
                type="button"
                class={[
                  "document-tab",
                  @document_modal_tab == tab.id && "active"
                ]}
                phx-click="switch_document_modal_tab"
                phx-value-tab={tab.id}
              >
                {tab.label}
              </button>
            <% end %>
          </div>

          <div class="document-modal-content">
            <%= case @document_modal_tab do %>
              <% "summary" -> %>
                <div style="font-size: 14px; color: #475569;">
                  {@document_modal_document.summary ||
                    "Summary not available yet. Once the ingestion pipeline completes, an overview of this PDF will appear here."}
                </div>
              <% "cleaned" -> %>
                <pre>{@document_modal_document.cleaned_content ||
    "Cleaned markdown will be available when ingestion completes."}</pre>
              <% "raw" -> %>
                <pre>{@document_modal_document.raw_content ||
    "Raw PDF text stream not available yet for this upload."}</pre>
              <% _ -> %>
                <div>Document preview unavailable.</div>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>

    <%= if @patient_modal_open do %>
      <div class="modal-backdrop" phx-click="close_patient_modal">
        <div class="patient-modal" phx-click="noop">
          <div>
            <div style="font-size: 12px; text-transform: uppercase; color: #94a3b8; letter-spacing: 0.08em;">
              Patient
            </div>
            <div style="font-size: 20px; font-weight: 600; color: #0f172a;">
              {patient_name(@patient)}
            </div>
            <div style="font-size: 13px; color: #475569;">
              MRN {patient_mrn(@patient)} · DOB {patient_dob(@patient)}
            </div>
          </div>

          <div class="patient-modal-grid">
            <div class="modal-column">
              <section class="modal-panel">
                <h3>Demographics</h3>
                <p style="font-size: 12px; color: #64748b; margin-bottom: 4px;">
                  Keep the patient’s preferred identifiers current for every report.
                </p>
                <.form
                  for={@profile_form}
                  id="patient-profile-form"
                  phx-change="validate_patient_profile"
                  phx-submit="save_patient_profile"
                  class="flex flex-col gap-3"
                >
                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                    <.input
                      field={@profile_form[:given_name]}
                      label="Given name"
                      placeholder="Ada"
                    />
                    <.input
                      field={@profile_form[:family_name]}
                      label="Family name"
                      placeholder="Lovelace"
                    />
                    <.input field={@profile_form[:mrn]} label="MRN" placeholder="MRN-10293" />
                    <.input
                      field={@profile_form[:date_of_birth]}
                      type="date"
                      label="Date of birth"
                    />
                  </div>
                  <div class="flex items-center justify-between text-xs text-slate-500">
                    <span>Saved instantly for all workspaces</span>
                    <button type="submit" class="btn btn-primary btn-sm">Save changes</button>
                  </div>
                </.form>
              </section>

              <section class="modal-panel">
                <div style="display: flex; align-items: center; justify-content: space-between;">
                  <h3>Workspace context</h3>
                  <.link navigate={~p"/prompts"} class="btn btn-ghost btn-xs">
                    Open prompts
                  </.link>
                </div>

                <div>
                  <div style="font-size: 12px; text-transform: uppercase; color: #94a3b8; letter-spacing: 0.08em;">
                    Recent runs
                  </div>
                  <div class="recent-runs">
                    <%= if Enum.empty?(@recent_runs) do %>
                      <div class="prompt-snippet">
                        No report runs for this workspace yet. Trigger “Run All Sections” to see activity.
                      </div>
                    <% else %>
                      <%= for run <- @recent_runs do %>
                        <div class="recent-run">
                          <header>
                            <span>{String.capitalize(run.run_type || "full")} run</span>
                            <span class="status-pill" data-status={run.status || "pending"}>
                              {run_status_label(run)}
                            </span>
                          </header>
                          <p>
                            {run_timestamp_label(run)}
                          </p>
                        </div>
                      <% end %>
                    <% end %>
                  </div>
                </div>

                <div class="prompt-summary">
                  <div>
                    <div style="font-size: 12px; text-transform: uppercase; color: #94a3b8; letter-spacing: 0.08em;">
                      Ingestion prompt
                    </div>
                    <div class="prompt-snippet">
                      {prompt_excerpt(@template.ingestion_prompt_template)}
                    </div>
                  </div>
                  <div>
                    <div style="font-size: 12px; text-transform: uppercase; color: #94a3b8; letter-spacing: 0.08em;">
                      Report sections ({length(@template.sections)})
                    </div>
                    <div class="prompt-section-list">
                      <%= for section <- Enum.take(@template.sections, 4) do %>
                        <span>{section.title}</span>
                      <% end %>
                    </div>
                    <div
                      :if={length(@template.sections) > 4}
                      style="font-size: 11px; color: #94a3b8; margin-top: 4px;"
                    >
                      +{length(@template.sections) - 4} additional sections configured in prompts.
                    </div>
                  </div>
                </div>
              </section>
            </div>

            <div class="modal-column">
              <section class="modal-panel">
                <h3>Workspaces</h3>
                <p style="font-size: 12px; color: #64748b;">
                  Switch between document sets for the same patient. Each workspace keeps its own runs.
                </p>
                <div class="workspace-list">
                  <%= for set <- @record_sets do %>
                    <button
                      type="button"
                      class={["workspace-item", set.id == @record_set.id && "active"]}
                      phx-click="select_record_set"
                      phx-value-id={set.id}
                    >
                      <div style="font-size: 13px; font-weight: 600; color: #0f172a;">
                        {set.label}
                      </div>
                      <div style="font-size: 12px; color: #475569;">Status: {set.status}</div>
                      <div style="font-size: 11px; color: #94a3b8;">
                        Updated {format_timestamp(set.updated_at)}
                      </div>
                      <div class="workspace-run-meta">
                        <%= if run = Map.get(@record_set_latest_runs, set.id) do %>
                          <span>
                            {String.capitalize(run.run_type || "full")} · {run_status_label(run)}
                          </span>
                          <span>{format_timestamp(run_timestamp(run))}</span>
                        <% else %>
                          <span>No report runs yet.</span>
                        <% end %>
                      </div>
                    </button>
                  <% end %>
                  <%= if Enum.empty?(@record_sets) do %>
                    <div style="font-size: 13px; color: #94a3b8;">No workspaces yet.</div>
                  <% end %>
                </div>
              </section>
            </div>
          </div>

          <div class="patient-actions" style="justify-content: flex-end;">
            <button
              id="create-record-set"
              class="btn btn-primary btn-sm"
              phx-click="create_record_set"
            >
              New Workspace
            </button>
            <button class="btn btn-ghost btn-sm" phx-click="close_patient_modal">Close</button>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  defp profile_form(patient, attrs \\ %{}, action \\ nil) do
    patient
    |> Patients.profile_changeset(attrs)
    |> apply_form_action(action)
    |> to_form(as: :profile)
  end

  defp profile_form_from_changeset(changeset, action) do
    changeset
    |> apply_form_action(action)
    |> to_form(as: :profile)
  end

  defp apply_form_action(changeset, nil), do: changeset
  defp apply_form_action(changeset, action), do: Map.put(changeset, :action, action)

  defp run_status_label(%{status: status}) when is_binary(status), do: String.capitalize(status)
  defp run_status_label(_), do: "Pending"

  defp run_timestamp(%{finished_at: %DateTime{} = dt}), do: dt
  defp run_timestamp(%{started_at: %DateTime{} = dt}), do: dt
  defp run_timestamp(%{updated_at: %DateTime{} = dt}), do: dt
  defp run_timestamp(%{inserted_at: %DateTime{} = dt}), do: dt
  defp run_timestamp(_), do: nil

  defp run_timestamp_label(run) do
    case run_timestamp(run) do
      nil -> "Updated recently"
      dt -> "Updated #{format_timestamp(dt)}"
    end
  end

  defp prompt_excerpt(nil), do: "Ingestion prompt not yet configured."

  defp prompt_excerpt(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> truncate(260)
  end

  defp truncate(text, limit) do
    if String.length(text) <= limit do
      text
    else
      String.slice(text, 0, limit) <> "…"
    end
  end

  defp patient_name(%{current_profile: nil}), do: "Patient"

  defp patient_name(%{current_profile: profile}) do
    Enum.filter([profile.given_name, profile.family_name], & &1)
    |> Enum.join(" ")
  end

  defp patient_display_name(patient) do
    name = patient_name(patient)
    mrn_label = label_or_nil("MRN", patient_mrn(patient))
    dob_label = label_or_nil("DOB", patient_dob(patient))

    label =
      [name, mrn_label, dob_label]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    cond do
      label != "" ->
        label

      patient.patient_key ->
        "Patient " <> String.slice(patient.patient_key, 0, 8)

      true ->
        "Patient"
    end
  end

  defp label_or_nil(_label, "N/A"), do: nil
  defp label_or_nil(label, value) when is_binary(value), do: "#{label} #{value}"
  defp label_or_nil(_label, _value), do: nil

  defp patient_mrn(%{current_profile: nil}), do: "N/A"
  defp patient_mrn(%{current_profile: profile}), do: profile.mrn || "N/A"

  defp patient_dob(%{current_profile: nil}), do: "N/A"

  defp patient_dob(%{current_profile: profile}) do
    profile.date_of_birth || "N/A"
  end

  defp status_label(%{last_run: nil}), do: "Not generated"
  defp status_label(%{last_run: %{status: "completed"}}), do: "Ready"
  defp status_label(%{last_run: %{status: "queued"}}), do: "Queued"
  defp status_label(%{last_run: %{status: "running"}}), do: "Running"
  defp status_label(%{last_run: %{status: "error"}}), do: "Needs attention"
  defp status_label(%{last_run: %{status: status}}), do: status

  defp format_timestamp(nil), do: "recently"
  defp format_timestamp(dt), do: Calendar.strftime(dt, "%b %d · %H:%M UTC")

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
