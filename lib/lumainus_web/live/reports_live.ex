defmodule LumainusWeb.ReportsLive do
  use LumainusWeb, :live_view

  alias Lumainus.Accounts
  alias Lumainus.Conversion.CloudStatus
  alias Lumainus.Conversion.Service, as: ConversionService
  alias Lumainus.Conversion.Events
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
  import LumainusWeb.ReportsLive.Formatting
  import LumainusWeb.ReportsLive.CitationHelpers
  import LumainusWeb.Components.ProgressStages
  require Logger

  @document_modal_tabs [
    %{id: "summary", label: "Summary"},
    %{id: "cleaned", label: "Full document"}
  ]
  @document_modal_tab_ids Enum.map(@document_modal_tabs, & &1.id)
  @document_summary_preview_bytes 1_000
  @document_sidebar_preview_bytes 50_000
  @document_modal_content_bytes 200_000
  @document_modal_summary_bytes 4_000

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    t0 = System.monotonic_time(:millisecond)
    Reports.bootstrap_workspace!(scope)
    t1 = System.monotonic_time(:millisecond)

    socket =
      socket
      |> assign(:page_head, mathjax_head())
      |> assign(:current_run_id, nil)
      |> allow_upload(:documents,
        accept: ~w(.pdf),
        max_entries: 5,
        max_file_size: 25_000_000,
        auto_upload: true,
        progress: &handle_upload_progress/3
      )
      |> load_workspace()

    t2 = System.monotonic_time(:millisecond)

    Logger.info(
      "[ReportsLive] mount timing - bootstrap: #{t1 - t0}ms, load_workspace: #{t2 - t1}ms, total: #{t2 - t0}ms"
    )

    socket =
      if connected?(socket) do
        # Subscribe to record set updates
        Documents.subscribe_to_record_set(socket.assigns.record_set.id)

        # Subscribe to GPU instance status changes from InstanceManager
        InstanceManager.subscribe()

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
        hydrated = maybe_hydrate_selected_document(doc)
        {:noreply, assign(socket, selected_document: hydrated)}
    end
  end

  @impl true
  def handle_event("clear_document", _params, socket) do
    {:noreply, assign(socket, selected_document: nil)}
  end

  @impl true
  def handle_event("open_document_modal", %{"doc-id" => doc_id} = params, socket) do
    Logger.debug("Looking for document with ID: #{inspect(doc_id)}")

    Logger.debug(
      "Available documents: #{inspect(Enum.map(socket.assigns.documents, &{&1.id, &1.sequence, &1.mock_id}))}"
    )

    line_start = parse_int(params["line-start"])
    line_end = parse_int(params["line-end"])
    ranges = normalize_ranges(line_start, line_end, params["ranges"])
    section_context = build_section_context(socket.assigns.visible_sections, params["section-id"])

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

        # Lazy-load document content only when modal opens
        content =
          Reports.get_document_content(doc.id,
            cleaned_limit: @document_modal_content_bytes,
            summary_limit: @document_modal_summary_bytes,
            include_raw?: false
          )

        doc_with_content =
          doc
          |> Map.put(:summary, content.summary || doc.summary)
          |> Map.put(:summary_truncated?, content.summary_truncated? || doc.summary_truncated?)
          |> Map.put(:summary_limit, content.summary_limit || @document_modal_summary_bytes)
          |> Map.put(:cleaned_content, content.cleaned_content)
          |> Map.put(:cleaned_truncated?, content.cleaned_truncated? || false)
          |> Map.put(:cleaned_limit, content.cleaned_limit || @document_modal_content_bytes)

        focus = build_focus_context(doc_with_content.cleaned_content, ranges)

        {:noreply,
         socket
         |> assign(:document_modal_document, doc_with_content)
         |> assign(:document_modal_section, section_context)
         |> assign(:document_modal_focus, focus)
         |> assign(:document_modal_tab, if(focus, do: "cleaned", else: "summary"))
         |> assign(:document_modal_open, true)}
    end
  end

  @impl true
  def handle_event("close_document_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:document_modal_document, nil)
     |> assign(:document_modal_focus, nil)
     |> assign(:document_modal_section, nil)
     |> assign(:document_modal_tab, "summary")
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

  def handle_event("select_debug_run", %{"run-id" => run_id}, socket) do
    scope = socket.assigns.current_scope
    run_details = Reports.get_report_run_with_details(scope, run_id)

    {:noreply,
     socket
     |> assign(:debug_selected_run_id, run_id)
     |> assign(:debug_selected_run, run_details)
     |> assign(:visible_sections, visible_sections(socket, run_details))
     |> assign(:visible_run_id, run_id)
     |> assign(:debug_expanded_sections, MapSet.new())}
  end

  def handle_event("toggle_debug_section", %{"section-id" => section_id}, socket) do
    expanded = socket.assigns.debug_expanded_sections

    updated =
      if MapSet.member?(expanded, section_id) do
        MapSet.delete(expanded, section_id)
      else
        MapSet.put(expanded, section_id)
      end

    {:noreply, assign(socket, :debug_expanded_sections, updated)}
  end

  def handle_event("toggle_debug_sections_all", %{"action" => action}, socket) do
    ids =
      case socket.assigns[:debug_selected_run] do
        %{section_runs: runs} when is_list(runs) -> Enum.map(runs, &to_string(&1.id))
        _ -> []
      end

    updated =
      case action do
        "expand" -> MapSet.new(ids)
        "collapse" -> MapSet.new()
        _ -> socket.assigns.debug_expanded_sections
      end

    {:noreply, assign(socket, :debug_expanded_sections, updated)}
  end

  def handle_event("set_docling_backend", %{"backend" => backend}, socket) do
    # Only admins can change backend
    unless socket.assigns.can_manage_gpu? do
      {:noreply,
       put_flash(socket, :error, "You don't have permission to change processing mode.")}
    else
      backend_atom =
        backend
        |> String.downcase()
        |> normalize_backend_atom()

      cond do
        backend_atom == :cloud and not socket.assigns.fast_available? ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Cloud (GPU) is unavailable (admin-only provisioning). Switched to Standard."
           )
           |> assign(:docling_backend, :local)}

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

  def handle_event("cancel_report_run", %{"run-id" => run_id}, socket) do
    Logger.info("[ReportsLive] cancel_report_run called with run_id=#{run_id}")

    case Reports.cancel_report_run(run_id) do
      {:ok, _run} ->
        Logger.info("[ReportsLive] cancel_report_run succeeded for run_id=#{run_id}")

        {:noreply,
         socket
         |> put_flash(:info, "Report run cancelled successfully.")
         |> load_workspace()}

      {:error, :not_found} ->
        Logger.warning("[ReportsLive] cancel_report_run failed: run_id=#{run_id} not found")

        {:noreply,
         socket
         |> put_flash(:error, "Report run not found.")
         |> load_workspace()}

      {:error, :already_completed} ->
        Logger.info(
          "[ReportsLive] cancel_report_run skipped: run_id=#{run_id} already completed/cancelled"
        )

        {:noreply,
         socket
         |> put_flash(:info, "Report run has already completed.")
         |> load_workspace()}

      {:error, reason} ->
        Logger.error(
          "[ReportsLive] cancel_report_run failed for run_id=#{run_id}: #{inspect(reason)}"
        )

        {:noreply,
         socket
         |> put_flash(:error, "Failed to cancel report run: #{inspect(reason)}")
         |> load_workspace()}
    end
  end

  def handle_event("seed_sample_documents", _params, socket) do
    Logger.info("[ReportsLive] seed_sample_documents handler called")
    Logger.info("[ReportsLive] Current documents count: #{length(socket.assigns.documents)}")
    scope = socket.assigns.current_scope

    try do
      result =
        Documents.seed_sample_documents(scope, socket.assigns.patient, socket.assigns.record_set)

      Logger.info("[ReportsLive] seed_sample_documents returned: #{inspect(result)}")

      case result do
        {:ok, :noop} ->
          Logger.info("[ReportsLive] No new documents (noop), calling load_workspace")

          updated_socket =
            socket |> put_flash(:info, "Sample documents already loaded.") |> load_workspace()

          Logger.info(
            "[ReportsLive] After load_workspace, documents count: #{length(updated_socket.assigns.documents)}"
          )

          {:noreply, updated_socket}

        {:ok, uploads} when is_list(uploads) ->
          Logger.info("[ReportsLive] Loaded #{length(uploads)} documents, calling load_workspace")

          updated_socket =
            socket
            |> put_flash(:info, "Loaded #{length(uploads)} sample documents.")
            |> load_workspace()

          Logger.info(
            "[ReportsLive] After load_workspace, documents count: #{length(updated_socket.assigns.documents)}"
          )

          {:noreply, updated_socket}

        {:error, reason} ->
          Logger.error("[ReportsLive] seed_sample_documents error: #{inspect(reason)}")

          {:noreply,
           socket
           |> put_flash(:error, "Failed to load sample documents: #{inspect(reason)}")
           |> load_workspace()}

        other ->
          Logger.error("[ReportsLive] seed_sample_documents unexpected result: #{inspect(other)}")

          {:noreply,
           socket
           |> put_flash(:error, "Unexpected result loading samples")
           |> load_workspace()}
      end
    rescue
      e ->
        Logger.error(
          "[ReportsLive] seed_sample_documents exception: #{inspect(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        {:noreply,
         socket
         |> put_flash(:error, "Error loading sample documents")
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
    # Persist the selection so it survives server restarts
    Accounts.update_last_patient(socket.assigns.current_scope.user, patient_id)

    {:noreply,
     socket
     |> assign(:patient_modal_open, false)
     |> load_workspace(patient_id: patient_id)}
  end

  def handle_event("create_patient", _params, socket) do
    scope = socket.assigns.current_scope

    case Reports.create_patient_for_scope(scope) do
      {:ok, patient} ->
        # Persist the selection so it survives server restarts
        Accounts.update_last_patient(scope.user, patient.id)

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
    ids = Enum.map(section_ids, &to_string/1)
    socket = lock_sections(socket, ids)
    send(self(), {:perform_section_runs, ids})
    {:noreply, socket}
  end

  defp lock_sections(socket, section_ids) do
    lock_set = MapSet.new(section_ids)

    updated_sections =
      Enum.map(socket.assigns.sections, fn entry ->
        if MapSet.member?(lock_set, to_string(entry.section.id)) do
          %{entry | status: lock_status(entry.status)}
        else
          entry
        end
      end)

    updated_visible_sections =
      Enum.map(socket.assigns.visible_sections, fn entry ->
        section_id = get_section_id(entry)

        if section_id && MapSet.member?(lock_set, to_string(section_id)) do
          update_entry_status(entry, lock_status(Map.get(entry, :status)))
        else
          entry
        end
      end)

    socket
    |> assign(:running_sections, MapSet.union(socket.assigns.running_sections, lock_set))
    |> assign(:sections, updated_sections)
    |> assign(:visible_sections, updated_visible_sections)
  end

  # Get section ID from different entry formats (section_entry vs section_run)
  defp get_section_id(%{section: %{id: id}}), do: id
  defp get_section_id(%{section_template_id: id}), do: id
  defp get_section_id(_), do: nil

  # Update status in different entry formats
  defp update_entry_status(%{status: _} = entry, new_status), do: %{entry | status: new_status}
  defp update_entry_status(entry, _new_status), do: entry

  defp lock_status(status) when status in ["running", "queued"], do: status
  defp lock_status(_status), do: "queued"

  defp perform_section_runs(socket, section_ids) do
    scope = socket.assigns.current_scope

    case Reports.run_sections(
           scope,
           socket.assigns.patient,
           socket.assigns.record_set,
           socket.assigns.template,
           section_ids,
           stream: true
         ) do
      {:ok, run} ->
        socket
        |> assign(:current_run_id, run.id)
        |> load_workspace()

      {:error, reason} ->
        socket
        |> put_flash(:error, "Report generation failed: #{inspect(reason)}")
        |> load_workspace()
    end
  end

  defp load_workspace(socket, opts \\ []) do
    _t_start = System.monotonic_time(:millisecond)
    scope = socket.assigns.current_scope
    has_patient_override = Keyword.has_key?(opts, :patient_id)

    record_set_id =
      if has_patient_override do
        Keyword.get(opts, :record_set_id)
      else
        Keyword.get(opts, :record_set_id) || socket.assigns[:active_record_set_id]
      end

    patient_id =
      Keyword.get(opts, :patient_id) ||
        (socket.assigns[:patient] && socket.assigns.patient.id) ||
        scope.user.last_patient_id

    t1 = System.monotonic_time(:millisecond)
    workspace = Reports.workspace(scope, record_set_id: record_set_id, patient_id: patient_id)
    t2 = System.monotonic_time(:millisecond)
    documents = format_documents(workspace.documents)

    sections = format_sections(workspace.sections)

    # TODO: Integrate with v2 HealthManager
    docling_health = nil

    # INSTANT: Get GPU status from InstanceManager state machine (no HTTP)
    # InstanceManager maintains health state via periodic background checks
    gpu_instance_status = check_gpu_instance_status_fast()

    # Derive fast_available? from CloudStatus via gpu_instance_status
    # No "Checking..." delays - trust CloudStatus as single source of truth
    {fast_available?, fast_reason} =
      case gpu_instance_status do
        %{status: :running, healthy: false, health_check_error: error} ->
          # Instance running but health check failed
          {false, error || "GPU service unhealthy"}

        %{status: :running, healthy: healthy} when healthy != false ->
          # Instance running and either healthy (true) or not yet checked (nil)
          {true, nil}

        %{status: :loading} ->
          # Provisioning - jobs will wait automatically
          {true, "GPU instance provisioning..."}

        %{status: :unavailable, health_check_error: error} ->
          {false, error || "GPU unavailable"}

        _ ->
          {false, "No GPU instance"}
      end

    # NO async health check on page load - InstanceManager handles this in background
    # Subscribe to PubSub for status updates instead (done in mount)

    # Doctors always use local backend (no GPU cost controls)
    can_manage_gpu? = scope.user.role in ["admin", "system_administrator"]

    selected_backend =
      if can_manage_gpu? do
        preferred_backend = Accounts.docling_backend_for_user(scope.user)
        # Only fall back to local if fast is explicitly unavailable (false)
        # When fast_available? is nil (Checking), allow cloud backend
        if preferred_backend == :cloud and fast_available? == false,
          do: :local,
          else: preferred_backend
      else
        :local
      end

    # Only include truly active sections - not "error" or "failed" which are terminal states
    # Error sections should show their error state, not pretend to be running
    # Also include "completed" sections that don't have output_markdown yet (race condition fix)
    # This prevents brief "Awaiting output" flash when status updates before content is visible
    running_sections =
      sections
      |> Enum.filter(fn section ->
        section.status in ["pending", "queued", "running"] ||
          (section.status == "completed" && !has_output?(section.last_run))
      end)
      |> Enum.map(& &1.section.id)
      |> MapSet.new()

    t3 = System.monotonic_time(:millisecond)
    record_sets = RecordSets.list_for_patient(workspace.patient)
    t4 = System.monotonic_time(:millisecond)
    record_set_latest_runs = Reports.latest_runs_for_record_sets(scope, record_sets)
    t5 = System.monotonic_time(:millisecond)
    recent_runs = Reports.list_runs_for_record_set(scope, workspace.record_set, limit: 5)
    t6 = System.monotonic_time(:millisecond)
    patients = Reports.list_patients_for_scope(scope)
    t7 = System.monotonic_time(:millisecond)

    # Load active runs for the jobs widget (admins see all, doctors see their own)
    is_admin = scope.user.role in ["admin", "system_administrator"]
    global_active_runs = Reports.list_active_runs(scope, is_admin: is_admin)
    t8 = System.monotonic_time(:millisecond)

    Logger.info(
      "[ReportsLive] load_workspace timing - workspace: #{t2 - t1}ms, record_sets: #{t4 - t3}ms, latest_runs: #{t5 - t4}ms, recent_runs: #{t6 - t5}ms, patients: #{t7 - t6}ms, active_runs: #{t8 - t7}ms"
    )

    # Find active run for cancel button
    # First try to find a run that's actively running/pending/queued
    # If not found but we have running sections, use the most recent run
    # (handles edge case where run errors but sections are stuck pending)
    active_run_id =
      case Enum.find(recent_runs, &(&1.status in ["running", "pending", "queued"])) do
        %{id: id} ->
          id

        nil ->
          cond do
            # If we have running sections, use most recent run (even if errored)
            MapSet.size(running_sections) > 0 and recent_runs != [] ->
              List.first(recent_runs).id

            # Fall back to previously set current_run_id
            true ->
              socket.assigns[:current_run_id]
          end
      end

    socket =
      socket
      |> assign(:patient, workspace.patient)
      |> assign(:record_set, workspace.record_set)
      |> assign(:template, workspace.template)
      |> assign(:documents, documents)
      |> assign(:sections, sections)
      |> assign(:running_sections, running_sections)
      |> assign(:current_run_id, active_run_id)
      |> assign(:record_sets, record_sets)
      |> assign(:record_set_latest_runs, record_set_latest_runs)
      |> assign(:recent_runs, recent_runs)
      |> assign(:patients, patients)
      |> assign(:global_active_runs, global_active_runs)
      |> assign(:visible_sections, sections)
      |> assign(:docling_health, docling_health)
      |> assign(:docling_backend, selected_backend)
      |> assign(:fast_available?, fast_available?)
      |> assign(:fast_unavailable_reason, format_backend_reason(fast_reason))
      |> maybe_disable_fast(fast_available?)
      |> assign(:gpu_instance_status, gpu_instance_status)
      |> assign(:can_manage_gpu?, can_manage_gpu?)
      |> assign(:profile_form, profile_form(workspace.patient))
      |> assign(:active_record_set_id, workspace.record_set.id)
      |> assign(:selected_document, nil)
      |> assign(:document_modal_document, nil)
      |> assign(:document_modal_section, nil)
      |> assign(:document_modal_open, false)
      |> assign(:document_modal_tab, "summary")
      |> assign_new(:upload_blocked_reason, fn -> nil end)
      |> assign_new(:patient_modal_open, fn -> false end)
      |> assign_new(:gpu_prompt_dismissed, fn -> false end)
      |> assign_new(:gpu_provisioning, fn -> false end)
      |> assign_new(:conversion_job_subscriptions, fn -> MapSet.new() end)
      |> assign_new(:record_set_subscriptions, fn -> MapSet.new() end)
      |> assign_new(:report_run_subscriptions, fn -> MapSet.new() end)
      |> assign_new(:visible_run_id, fn -> nil end)
      |> assign_new(:document_modal_focus, fn -> nil end)
      |> assign_new(:streaming_content, fn -> %{} end)
      |> assign(:health_check_retry_count, 0)
      |> assign_debug_panel(scope)

    socket
    |> maybe_refresh_document_modal()
    |> maybe_subscribe_record_set(workspace.record_set.id)
    |> maybe_subscribe_report_runs(workspace.record_set.id)
    |> subscribe_to_job_topics()
  end

  defp assign_debug_panel(socket, scope) do
    t1 = System.monotonic_time(:millisecond)
    # Keep debug list light to avoid heavy preloads / JSON decode
    all_runs = Reports.list_runs_for_record_set(scope, socket.assigns.record_set, limit: 8)
    t2 = System.monotonic_time(:millisecond)

    # Default to most recent run
    selected_run_id =
      socket.assigns[:debug_selected_run_id] ||
        (List.first(all_runs) && List.first(all_runs).id)

    selected_run_details =
      if selected_run_id do
        Reports.get_report_run_with_details(scope, selected_run_id)
      else
        nil
      end

    t3 = System.monotonic_time(:millisecond)

    Logger.info(
      "[ReportsLive] debug_panel timing - list_runs: #{t2 - t1}ms, get_details: #{t3 - t2}ms"
    )

    socket
    |> assign(:debug_runs, all_runs)
    |> assign(:debug_selected_run_id, selected_run_id)
    |> assign(:debug_selected_run, selected_run_details)
    |> assign(:visible_sections, visible_sections(socket, selected_run_details))
    |> assign(:visible_run_id, selected_run_id)
    |> assign_new(:debug_expanded_sections, fn -> MapSet.new() end)
  end

  @impl true
  def handle_info({:perform_section_runs, section_ids}, socket) do
    {:noreply, perform_section_runs(socket, section_ids)}
  end

  @impl true
  def handle_info({:documents_changed, record_set_id}, socket) do
    if socket.assigns.record_set.id == record_set_id do
      {:noreply, load_workspace(socket)}
    else
      {:noreply, socket}
    end
  end

  # Handle conversion job started event - subscribe immediately without full reload
  # This is critical: load_workspace takes 2-3 seconds and progress events would
  # be missed during that time. By subscribing immediately, we catch all events.
  def handle_info({:conversion_job_started, record_set_id, upload_id, conversion_job_id}, socket) do
    if socket.assigns.record_set.id == record_set_id do
      Logger.debug(
        "[ReportsLive] conversion_job_started: upload=#{upload_id} job_id=#{conversion_job_id}"
      )

      # Subscribe to the conversion job immediately
      if not MapSet.member?(socket.assigns.conversion_job_subscriptions, conversion_job_id) do
        Events.subscribe(conversion_job_id)
      end

      # Update the document with the new job ID without full reload
      updated_docs =
        Enum.map(socket.assigns.documents, fn doc ->
          if doc.id == upload_id do
            %{doc | docling_job_id: conversion_job_id}
          else
            doc
          end
        end)

      socket =
        socket
        |> assign(:documents, updated_docs)
        |> assign(
          :conversion_job_subscriptions,
          MapSet.put(socket.assigns.conversion_job_subscriptions, conversion_job_id)
        )

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # =============================================================================
  # v2 Conversion Events Handlers
  # =============================================================================

  def handle_info({:conversion_job, :progress, %{job_id: job_id, progress: progress}}, socket) do
    Logger.debug(
      "[ReportsLive] RECEIVED progress event: job_id=#{job_id} progress=#{progress} pid=#{inspect(self())} subscriptions=#{inspect(MapSet.to_list(socket.assigns.conversion_job_subscriptions))}"
    )

    # Update any document that has this conversion_job_id in its metadata
    updated_docs = update_v2_conversion_progress(socket.assigns.documents, job_id, progress)
    {:noreply, assign(socket, :documents, updated_docs)}
  end

  def handle_info({:conversion_job, :completed, %{id: job_id} = _job}, socket) do
    Logger.info("[ReportsLive] v2 conversion completed: job_id=#{job_id}")

    socket =
      socket
      |> put_flash(:info, "Conversion complete")
      |> load_workspace()

    {:noreply, socket}
  end

  def handle_info({:conversion_job, :failed, %{job_id: job_id, reason: reason}}, socket) do
    Logger.warning(
      "[ReportsLive] v2 conversion failed: job_id=#{job_id} reason=#{inspect(reason)}"
    )

    socket =
      socket
      |> put_flash(:error, "Conversion failed: #{format_v2_error(reason)}")
      |> load_workspace()

    {:noreply, socket}
  end

  def handle_info({:conversion_job, :cancelled, %{id: job_id}}, socket) do
    Logger.info("[ReportsLive] v2 conversion cancelled: job_id=#{job_id}")
    {:noreply, load_workspace(socket)}
  end

  def handle_info({:conversion_job, :submitted, %{id: job_id}}, socket) do
    Logger.debug("[ReportsLive] v2 conversion submitted: job_id=#{job_id}")
    {:noreply, socket}
  end

  def handle_info({:section_run_updated, record_set_id}, socket) do
    if socket.assigns.record_set.id == record_set_id do
      socket = load_workspace(socket)

      # Clean up streaming content for sections no longer running
      cleaned_streaming =
        socket.assigns.streaming_content
        |> Enum.filter(fn {section_id, _} ->
          MapSet.member?(socket.assigns.running_sections, section_id)
        end)
        |> Map.new()

      {:noreply, assign(socket, :streaming_content, cleaned_streaming)}
    else
      {:noreply, socket}
    end
  end

  # Handle incoming LLM stream chunk
  def handle_info({:llm_chunk, %{section_run_id: section_run_id, text: text}}, socket) do
    section_id = find_section_id_for_run(socket, section_run_id)

    if section_id && MapSet.member?(socket.assigns.running_sections, section_id) do
      current = Map.get(socket.assigns.streaming_content, section_id, "")
      updated_content = current <> text

      # Truncate if too long (performance safeguard)
      truncated =
        if String.length(updated_content) > 10_000 do
          "..." <> String.slice(updated_content, -8000, 8000)
        else
          updated_content
        end

      {:noreply,
       assign(
         socket,
         :streaming_content,
         Map.put(socket.assigns.streaming_content, section_id, truncated)
       )}
    else
      {:noreply, socket}
    end
  end

  # Handle GPU status changes from InstanceManager PubSub
  # This is the PRIMARY way to get status updates - no HTTP polling needed
  def handle_info({:gpu_status_changed, status_map}, socket) do
    Logger.debug(
      "[ReportsLive] GPU status changed: status=#{status_map.status} healthy=#{status_map.healthy}"
    )

    # Derive fast_available? from the new status
    {fast_available?, fast_reason} =
      case status_map do
        %{status: :running, healthy: false, health_check_error: error} ->
          {false, error || "GPU service unhealthy"}

        %{status: :running, healthy: healthy} when healthy != false ->
          {true, nil}

        %{status: :loading} ->
          {false, "GPU instance still loading"}

        %{status: :stopped} ->
          {false, "GPU instance stopped"}

        _ ->
          {false, "No GPU instance"}
      end

    # Normalize status for UI
    normalized_status =
      case status_map.status do
        :running -> :running
        :stopped -> :stopped
        :loading -> :loading
        :none -> :no_instance
        _ -> :unknown
      end

    gpu_instance_status = %{
      status: normalized_status,
      endpoint: status_map.endpoint,
      instance_id: status_map.instance_id,
      healthy: status_map.healthy,
      health_check_error: status_map.health_check_error
    }

    {:noreply,
     socket
     |> assign(:gpu_instance_status, gpu_instance_status)
     |> assign(:fast_available?, fast_available?)
     |> assign(:fast_unavailable_reason, format_backend_reason(fast_reason))}
  end

  # DEPRECATED: Keep for backwards compatibility but no longer triggered from load_workspace
  # InstanceManager now handles health checks in background
  def handle_info(:check_fast_backend_health, socket) do
    # No-op - health checks are now handled by InstanceManager
    Logger.debug("[ReportsLive] Ignoring legacy :check_fast_backend_health message")
    {:noreply, socket}
  end

  def handle_info({:fast_backend_health_result, {available?, reason}}, socket) do
    # When health check fails but we know an instance exists, show better status
    # This handles the case where instance was just provisioned but service is still booting
    #
    # IMPORTANT: Check InstanceManager directly for current state, not socket assigns
    # which may be stale from page load
    current_instance_status = check_gpu_instance_status_fast()

    Logger.info(
      "[ReportsLive] Health result received: available?=#{inspect(available?)}, " <>
        "instance_status=#{inspect(current_instance_status.status)}"
    )

    {final_available?, final_reason, should_retry?} =
      case {available?, current_instance_status} do
        {true, _} ->
          # Health check passed - all good
          Logger.info("[ReportsLive] Setting fast_available?=true")
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
      # PREFLIGHT CHECK: If cloud is selected, verify GPU is available BEFORE processing
      case preflight_backend_check(socket) do
        :ok ->
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

        {:error, reason} ->
          Logger.warning(
            "[ReportsLive] UPLOAD BLOCKED - cloud unavailable: #{entry.client_name} reason=#{reason}"
          )

          message =
            "Cloud GPU unavailable (#{reason}). Start a GPU instance or switch to Standard and re-upload."

          # Cancel the upload entry to clean up
          {:noreply,
           socket
           |> assign(:docling_backend, :local)
           |> cancel_upload(:documents, entry.ref)
           |> assign(:upload_blocked_reason, message)
           |> put_flash(
             :error,
             "Cannot upload: Cloud GPU is not available (#{reason}). Start a GPU instance or switch to Local mode."
           )}
      end
    else
      {:noreply, socket}
    end
  end

  defp handle_upload_progress(_name, _entry, socket), do: {:noreply, socket}

  defp entry_processed(socket, {:ok, {:success, payload}}) do
    handle_consumed_entry(payload, socket |> assign(:upload_blocked_reason, nil))
  end

  defp entry_processed(socket, {:success, payload}) do
    handle_consumed_entry(payload, socket |> assign(:upload_blocked_reason, nil))
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
         |> put_flash(:info, "#{meta.filename} queued for ingestion.")
         |> load_workspace()}

      {:error, :already_queued, updated_socket} ->
        {:noreply,
         updated_socket
         |> put_flash(:warning, "#{meta.filename} is already being processed.")
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
             |> put_flash(
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
             |> put_flash(:error, "Failed to queue #{meta.filename}: #{inspect(reason)}")}
        end

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
      metadata = doc.metadata || %{}
      label = metadata["label"] || Path.rootname(doc.filename)

      summary_text =
        metadata["summary"] ||
          metadata["ingestion_message"] ||
          "Open document to load summary"

      {summary, summary_truncated?} =
        truncate_with_flag(summary_text, @document_summary_preview_bytes)

      provider = metadata["provider"] || "Unknown source"
      date = metadata["date"] || Calendar.strftime(doc.inserted_at, "%Y-%m-%d")
      ingestion_state = metadata["ingestion_state"]
      ingestion_stage = metadata["ingestion_stage"]
      ingestion_progress = (metadata["ingestion_progress"] || 0) / 1.0
      ingestion_message = metadata["ingestion_message"]
      ingestion_error = metadata["ingestion_error"]
      job_id = metadata["ingestion_job_id"]
      status = ingestion_state || doc.status || metadata["status"] || ingestion_stage
      timeout_at = metadata["ingestion_timeout_at"]
      progress_payload = metadata["progress"] || %{}
      backend = metadata["docling_backend"] || metadata["backend"] || "local"
      backend_status = metadata["docling_backend_status"]
      docling_job_id = metadata["docling_job_id"]
      conversion_profile = metadata["conversion_profile"]

      %{
        id: doc.id,
        sequence: index,
        filename: doc.filename,
        mock_id: metadata["mock_id"],
        label: label,
        summary: summary,
        summary_truncated?: summary_truncated?,
        provider: provider,
        date: date,
        kind: doc.document_kind,
        # Lazy-load content only when modal opens (avoid MB+ data in socket)
        cleaned_content: nil,
        cleaned_truncated?: false,
        raw_content: nil,
        status: status,
        ingestion_state: ingestion_state || status,
        ingestion_stage: ingestion_stage,
        ingestion_progress: ingestion_progress,
        ingestion_message: ingestion_message,
        ingestion_error: ingestion_error,
        ingestion_job_id: job_id,
        docling_job_id: docling_job_id,
        ingestion_timeout_at: timeout_at,
        progress: progress_payload,
        backend: backend,
        backend_status: backend_status,
        conversion_profile: conversion_profile,
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

  defp visible_sections(socket, nil), do: socket.assigns.sections || []

  defp visible_sections(_socket, run_details), do: sections_from_run(run_details)

  defp sections_from_run(%{section_runs: section_runs}) when is_list(section_runs) do
    section_runs
    |> Enum.sort_by(fn sr ->
      if sr.section_template, do: sr.section_template.position || 0, else: 0
    end)
    |> Enum.map(fn sr ->
      %{
        section: sr.section_template,
        last_run: format_run(sr),
        status: sr.status || (sr.output_markdown && "completed") || "pending"
      }
    end)
  end

  defp sections_from_run(_), do: []

  defp build_focus_context(_content, ranges) when ranges == [] or is_nil(ranges), do: nil

  defp build_focus_context(content, ranges) when is_list(ranges) do
    {min_start, max_end} =
      ranges
      |> Enum.reduce({nil, nil}, fn {s, e}, {min_acc, max_acc} ->
        {
          if(min_acc, do: min(min_acc, s), else: s),
          if(max_acc, do: max(max_acc, e), else: e)
        }
      end)

    min_start = min_start || 1
    max_end = max_end || min_start

    numbered =
      (content || "")
      |> to_string()
      |> String.split("\n")
      |> Enum.reduce({[], 1}, fn line, {acc, idx} ->
        trimmed = String.trim_trailing(line)

        if String.trim(trimmed) == "" do
          {acc, idx}
        else
          {[{idx, trimmed} | acc], idx + 1}
        end
      end)
      |> elem(0)
      |> Enum.reverse()

    window_start = max(min_start - 2, 1)
    window_end = max_end + 2

    lines =
      numbered
      |> Enum.filter(fn {num, _} -> num >= window_start and num <= window_end end)
      |> Enum.map(fn {num, text} ->
        %{
          number: num,
          text: text,
          highlight: Enum.any?(ranges, fn {s, e} -> num >= s and num <= e end)
        }
      end)

    if lines == [] do
      nil
    else
      %{
        line_start: min_start,
        line_end: max_end,
        lines: lines,
        ranges: ranges
      }
    end
  end

  defp build_section_context(_sections, nil), do: nil

  defp build_section_context(sections, section_id) when is_list(sections) do
    section =
      Enum.find(sections, fn entry ->
        entry.section && to_string(entry.section.id) == to_string(section_id)
      end)

    if section && section.last_run && section.last_run.output_markdown do
      %{
        title: section.section && section.section.title,
        excerpt: section_excerpt(section.last_run.output_markdown)
      }
    else
      nil
    end
  end

  defp build_section_context(_sections, _), do: nil

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

  defp maybe_disable_fast(socket, fast_available?) do
    if fast_available? do
      socket
    else
      assign(socket, :docling_backend, :local)
    end
  end

  defp subscribe_to_job_topics(socket) do
    if connected?(socket) do
      subscribe_to_conversion_jobs(socket)
    else
      socket
    end
  end

  defp subscribe_to_conversion_jobs(socket) do
    job_ids =
      socket.assigns.documents
      |> Enum.map(& &1.docling_job_id)
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    new_ids = MapSet.difference(job_ids, socket.assigns.conversion_job_subscriptions)

    Logger.debug(
      "[ReportsLive] subscribe_to_conversion_jobs: all_job_ids=#{inspect(MapSet.to_list(job_ids))} new_ids=#{inspect(MapSet.to_list(new_ids))} existing=#{inspect(MapSet.to_list(socket.assigns.conversion_job_subscriptions))}"
    )

    Enum.each(new_ids, &Events.subscribe/1)

    assign(
      socket,
      :conversion_job_subscriptions,
      MapSet.union(socket.assigns.conversion_job_subscriptions, new_ids)
    )
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
    cf_token = System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_API_TOKEN")
    cf_zone = System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_ZONE_ID")

    cf_fqdn =
      (System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_FQDN") || Cloudflare.cloud_fqdn())
      |> normalize_fqdn()

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
      "Calling VastAI.provision(offer_id: #{offer_id}, disk_gb: 20, label: medlumai-docling, onstart: <script>)"
    )

    case VastAI.provision(
           offer_id: offer_id,
           disk_gb: 20,
           label: "medlumai-docling",
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
    fqdn =
      (System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_FQDN") || Cloudflare.cloud_fqdn())
      |> normalize_fqdn()

    zone_id = System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_ZONE_ID")
    token = System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_API_TOKEN")

    missing_cloudflare? =
      is_nil(fqdn) or zone_id in [nil, ""] or token in [nil, ""]

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

  defp format_backend_reason(nil), do: ""

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

  # =============================================================================
  # v2 Conversion Helpers
  # =============================================================================

  defp update_v2_conversion_progress(documents, job_id, progress) do
    Enum.map(documents, fn doc ->
      if docling_job_match?(doc.docling_job_id, job_id) do
        current_progress = (doc.ingestion_progress || 0) / 1.0
        normalized_progress = normalize_v2_progress(progress, current_progress)
        new_state = if normalized_progress >= 100, do: "completed", else: "running"
        stage = doc.ingestion_stage || "docling"

        payload = %{
          "overall" => normalized_progress,
          "stage" => stage,
          "stage_name" => stage,
          "stage_progress" => normalized_progress,
          "pages_done" => Map.get(doc.progress || %{}, "pages_done"),
          "pages_total" => Map.get(doc.progress || %{}, "pages_total")
        }

        doc
        |> Map.put(:status, new_state)
        |> Map.put(:ingestion_state, new_state)
        |> Map.put(:ingestion_stage, stage)
        |> Map.put(:ingestion_progress, normalized_progress)
        |> Map.put(
          :ingestion_message,
          doc.ingestion_message || "Docling conversion in progress"
        )
        |> maybe_put_progress(payload)
      else
        doc
      end
    end)
  end

  defp format_v2_error(:service_unavailable), do: "No conversion backends available"
  defp format_v2_error(:file_too_large), do: "File exceeds 100MB limit"
  defp format_v2_error(:invalid_content_type), do: "Only PDF files are supported"
  defp format_v2_error(:timeout), do: "Conversion timed out"
  defp format_v2_error(reason), do: inspect(reason)

  defp docling_job_match?(nil, _job_id), do: false

  defp docling_job_match?(docling_job_id, job_id) do
    to_string(docling_job_id) == to_string(job_id)
  end

  defp maybe_hydrate_selected_document(doc) do
    cond do
      doc.cleaned_content ->
        doc

      not document_parsed?(doc) ->
        doc

      true ->
        content =
          Reports.get_document_content(doc.id,
            cleaned_limit: @document_sidebar_preview_bytes,
            summary_limit: @document_summary_preview_bytes,
            include_raw?: false
          )

        doc
        |> Map.put(:summary, content.summary || doc.summary)
        |> Map.put(:summary_truncated?, content.summary_truncated? || doc.summary_truncated?)
        |> Map.put(:cleaned_content, content.cleaned_content)
        |> Map.put(
          :cleaned_truncated?,
          content.cleaned_truncated? || doc.cleaned_truncated? || false
        )
        |> Map.put(:cleaned_limit, content.cleaned_limit || @document_sidebar_preview_bytes)
    end
  end

  defp document_parsed?(doc) do
    doc.ingestion_stage == "completed" or doc.status == "parsed"
  end

  defp normalize_v2_progress(nil, current), do: current

  defp normalize_v2_progress(progress, _current) when is_float(progress) do
    # Keep 2 decimal places for smooth progress updates
    progress
    |> max(0.0)
    |> min(100.0)
    |> Float.round(2)
  end

  defp normalize_v2_progress(progress, _current) when is_integer(progress) do
    # Convert integers to floats with 2 decimal places
    (progress / 1)
    |> max(0.0)
    |> min(100.0)
    |> Float.round(2)
  end

  defp normalize_v2_progress(_progress, current), do: current

  # Show progress bar when document is NOT fully parsed/completed
  defp show_progress_bar?(doc) do
    # Simple: if status is "parsed" or stage is "completed", hide. Otherwise show.
    not (doc.status == "parsed" or doc.ingestion_stage == "completed")
  end

  defp backend_label(%{conversion_profile: profile, backend: backend}) do
    case normalize_conversion_profile(profile) do
      nil -> backend_label(backend)
      normalized -> backend_label(normalized)
    end
  end

  defp backend_label(%{conversion_profile: profile}) when not is_nil(profile),
    do: backend_label(normalize_conversion_profile(profile))

  defp backend_label(backend) do
    case profile_for_backend(backend) do
      :enhanced -> "Enhanced (GPU)"
      _ -> "Standard (Local)"
    end
  end

  defp backend_badge_class(subject, status \\ nil)

  defp backend_badge_class(%{conversion_profile: profile, backend: backend}, status) do
    case normalize_conversion_profile(profile) do
      nil -> backend_badge_class(backend, status)
      normalized -> backend_badge_class(normalized, status)
    end
  end

  defp backend_badge_class(%{conversion_profile: profile}, status) when not is_nil(profile),
    do: backend_badge_class(normalize_conversion_profile(profile), status)

  defp backend_badge_class(backend, status) do
    base_class =
      case profile_for_backend(backend) do
        :enhanced -> "bg-sky-100 text-sky-700 border border-sky-200"
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

  defp maybe_put_progress(doc, payload) when is_map(payload) do
    existing_progress = doc.progress || %{}
    current_overall = (existing_progress["overall"] || doc.ingestion_progress || 0) / 1.0
    current_stage_progress = (existing_progress["stage_progress"] || 0) / 1.0
    current_pages_done = existing_progress["pages_done"] || 0
    current_pages_total = existing_progress["pages_total"]

    incoming_overall = payload[:overall] || payload["overall"]
    incoming_stage_progress = payload[:stage_progress] || payload["stage_progress"]
    incoming_pages_done = payload[:pages_done] || payload["pages_done"]
    incoming_pages_total = payload[:pages_total] || payload["pages_total"]

    overall = max(current_overall, incoming_overall || current_overall)

    stage_progress =
      max(current_stage_progress, incoming_stage_progress || current_stage_progress)

    pages_done = max(current_pages_done, incoming_pages_done || current_pages_done)
    pages_total = incoming_pages_total || current_pages_total

    # Convert atom keys to string keys for consistency with component
    progress = %{
      "overall" => overall,
      "stage" => payload[:stage] || payload["stage"] || existing_progress["stage"],
      "stage_name" =>
        payload[:stage_name] || payload["stage_name"] || existing_progress["stage_name"],
      "stage_progress" => stage_progress,
      "pages_done" => pages_done,
      "pages_total" => pages_total,
      "stages" => payload[:stages] || payload["stages"] || existing_progress["stages"] || %{}
    }

    Map.put(doc, :progress, progress)
  end

  defp normalize_fqdn(fqdn) do
    case fqdn do
      nil ->
        nil

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
    end
  end

  defp run_status(%{latest_run: nil}), do: "not_started"
  defp run_status(%{latest_run: %{status: status}}), do: status

  # Check if a section run has meaningful output content
  # Used to keep spinner showing until content is actually available (race condition fix)
  defp has_output?(nil), do: false
  defp has_output?(%{output_markdown: nil}), do: false
  defp has_output?(%{output_markdown: ""}), do: false
  defp has_output?(%{output_markdown: md}) when is_binary(md), do: String.trim(md) != ""
  defp has_output?(_), do: false

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

      .run-progress-indicator {
        display: flex;
        align-items: center;
        gap: 10px;
        padding: 8px 16px;
        background: #f0fdf4;
        border: 1px solid #86efac;
        border-radius: 999px;
        font-size: 13px;
        font-weight: 600;
        color: #166534;
        animation: indicator-glow 2s ease-in-out infinite;
      }

      @keyframes indicator-glow {
        0%, 100% {
          box-shadow: 0 0 8px 2px rgba(34, 197, 94, 0.3);
        }
        50% {
          box-shadow: 0 0 20px 6px rgba(34, 197, 94, 0.5);
        }
      }

      .progress-pulse {
        width: 10px;
        height: 10px;
        background: #22c55e;
        border-radius: 50%;
        animation: pulse-glow 1.2s ease-in-out infinite;
      }

      @keyframes pulse-glow {
        0%, 100% {
          transform: scale(1);
          box-shadow: 0 0 4px 2px rgba(34, 197, 94, 0.6);
        }
        50% {
          transform: scale(1.3);
          box-shadow: 0 0 12px 6px rgba(34, 197, 94, 0.8);
        }
      }

      .progress-text {
        letter-spacing: 0.02em;
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

      .document-focus {
        border: 1px solid #e2e8f0;
        border-radius: 12px;
        padding: 12px;
        background: #f8fafc;
        margin-bottom: 12px;
      }

      .document-focus-header {
        font-size: 12px;
        color: #475569;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        margin-bottom: 8px;
      }

      .document-section-snippet {
        border: 1px solid #e2e8f0;
        border-radius: 12px;
        padding: 10px 12px;
        background: #fff;
        margin-bottom: 10px;
      }

      .document-section-snippet h4 {
        margin: 0 0 4px 0;
        font-size: 12px;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        color: #94a3b8;
      }

      .document-section-snippet .snippet-text {
        font-size: 12px;
        color: #475569;
      }

      .document-focus-lines {
        max-height: 220px;
        overflow-y: auto;
        display: flex;
        flex-direction: column;
        gap: 4px;
      }

      .focus-line {
        display: flex;
        gap: 8px;
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
        font-size: 12px;
        padding: 4px 8px;
        border-radius: 8px;
        background: #fff;
        border: 1px solid #e2e8f0;
      }

      .focus-line.active {
        border-color: #2563eb;
        background: #e0e7ff;
      }

      .focus-line-number {
        width: 52px;
        color: #475569;
        flex-shrink: 0;
      }

      .focus-line pre {
        margin: 0;
        white-space: pre-wrap;
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
        gap: 3px;
        border-radius: 999px;
        border: 1px solid #c7d2fe;
        background: #edf2ff;
        color: #3730a3;
        padding: 1px 8px;
        font-size: 11px;
        font-weight: 500;
        cursor: pointer;
        transition: background 160ms ease, color 160ms ease, box-shadow 160ms ease, transform 100ms ease;
        margin: 0 2px;
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

      /* Debug Panel Styles */
      .debug-panel {
        background: #fff;
        border: 1px solid #e2e8f0;
        border-radius: 16px;
        margin-top: 24px;
      }

      .debug-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 16px 20px;
        border-bottom: 1px solid #e2e8f0;
        gap: 16px;
      }

      .debug-header h3 {
        margin: 0;
        font-size: 14px;
        font-weight: 600;
        color: #475569;
        display: flex;
        align-items: center;
        gap: 8px;
      }

      .debug-select {
        padding: 6px 12px;
        border: 1px solid #e2e8f0;
        border-radius: 8px;
        font-size: 13px;
        background: #f8fafc;
        color: #0f172a;
        min-width: 280px;
      }

      .debug-run-meta {
        display: flex;
        gap: 16px;
        padding: 12px 20px;
        background: #f8fafc;
        border-bottom: 1px solid #e2e8f0;
        font-size: 12px;
        flex-wrap: wrap;
      }

      .debug-meta-item {
        display: flex;
        flex-direction: column;
        gap: 2px;
      }

      .debug-meta-label {
        color: #94a3b8;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        font-size: 10px;
      }

      .debug-meta-value {
        color: #0f172a;
        font-weight: 500;
      }

      .debug-sections {
        max-height: 600px;
        overflow-y: auto;
      }

      .debug-footer-actions {
        display: flex;
        justify-content: flex-end;
        gap: 8px;
        padding: 12px 20px 16px;
        border-top: 1px solid #e2e8f0;
        background: #f8fafc;
      }

      .debug-section {
        border-bottom: 1px solid #e2e8f0;
      }

      .debug-section:last-child {
        border-bottom: none;
      }

      .debug-section-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 12px 20px;
        cursor: pointer;
        transition: background 0.15s ease;
        gap: 12px;
      }

      .debug-section-header:hover {
        background: #f8fafc;
      }

      .debug-section-title {
        font-size: 13px;
        font-weight: 600;
        color: #0f172a;
        flex: 1;
      }

      .debug-section-status {
        font-size: 11px;
        padding: 2px 8px;
        border-radius: 999px;
        font-weight: 500;
      }

      .debug-section-status[data-status="completed"] {
        background: #dcfce7;
        color: #166534;
      }

      .debug-section-status[data-status="error"] {
        background: #fef2f2;
        color: #b91c1c;
      }

      .debug-section-status[data-status="running"],
      .debug-section-status[data-status="queued"] {
        background: #fef3c7;
        color: #b45309;
      }

      .debug-section-status[data-status="pending"] {
        background: #f1f5f9;
        color: #64748b;
      }

      .debug-chevron {
        width: 16px;
        height: 16px;
        color: #94a3b8;
        transition: transform 0.15s ease;
      }

      .debug-chevron.expanded {
        transform: rotate(180deg);
      }

      .debug-section-content {
        padding: 0 20px 16px;
        display: flex;
        flex-direction: column;
        gap: 12px;
      }

      .debug-block {
        background: #f8fafc;
        border: 1px solid #e2e8f0;
        border-radius: 8px;
        overflow: hidden;
      }

      .debug-block-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 8px 12px;
        background: #f1f5f9;
        border-bottom: 1px solid #e2e8f0;
        font-size: 11px;
        font-weight: 600;
        color: #64748b;
        text-transform: uppercase;
        letter-spacing: 0.05em;
      }

      .debug-block-badge {
        font-size: 10px;
        padding: 2px 6px;
        border-radius: 4px;
        background: #e0e7ff;
        color: #4338ca;
        font-weight: 500;
        text-transform: none;
        letter-spacing: normal;
      }

      .debug-block-content {
        padding: 12px;
        font-size: 12px;
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
        white-space: pre-wrap;
        word-break: break-word;
        max-height: 300px;
        overflow-y: auto;
        color: #334155;
        line-height: 1.5;
      }

      .debug-block-content.json {
        color: #0f172a;
      }

      .debug-citation-row {
        display: flex;
        flex-wrap: wrap;
        gap: 6px;
        margin-bottom: 6px;
      }

      .debug-citation-chip {
        font-size: 11px;
        padding: 2px 8px;
        border-radius: 6px;
        background: #e0f2fe;
        color: #075985;
        border: 1px solid #bae6fd;
      }

      .debug-citation-excerpt {
        font-size: 11px;
        padding: 4px 8px;
        border-radius: 6px;
        background: #f8fafc;
        color: #475569;
        border: 1px dashed #e2e8f0;
      }

      .debug-usage-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
        gap: 8px;
        padding: 12px;
      }

      .debug-usage-item {
        text-align: center;
        padding: 8px;
        background: #fff;
        border-radius: 6px;
      }

      .debug-usage-value {
        font-size: 16px;
        font-weight: 600;
        color: #0f172a;
      }

      .debug-usage-label {
        font-size: 10px;
        color: #94a3b8;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        margin-top: 2px;
      }

      .debug-empty {
        padding: 40px 20px;
        text-align: center;
        color: #94a3b8;
        font-size: 13px;
      }

      .debug-error-content {
        background: #fef2f2;
        color: #b91c1c;
      }

      /* Prompt tooltip */
      .prompt-tooltip-wrapper {
        position: relative;
        display: inline-block;
      }

      .prompt-tooltip-btn {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        padding: 6px 12px;
        font-size: 12px;
        font-weight: 600;
        color: #6366f1;
        background: #eef2ff;
        border: 1px solid #c7d2fe;
        border-radius: 6px;
        cursor: pointer;
        transition: all 0.15s ease;
      }

      .prompt-tooltip-btn:hover {
        background: #e0e7ff;
        border-color: #a5b4fc;
      }

      .prompt-tooltip-content {
        display: none;
        position: absolute;
        top: 100%;
        right: 0;
        padding-top: 8px;
        width: 500px;
        max-width: 90vw;
        z-index: 50;
      }

      .prompt-tooltip-content-inner {
        position: relative;
        max-height: 400px;
        overflow-y: auto;
        padding: 16px;
        background: #1e293b;
        color: #f1f5f9;
        border-radius: 12px;
        box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.2), 0 10px 10px -5px rgba(0, 0, 0, 0.1);
        font-size: 13px;
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
        white-space: pre-wrap;
        word-break: break-word;
        line-height: 1.5;
      }

      .prompt-tooltip-wrapper:hover .prompt-tooltip-content {
        display: block;
      }

      .prompt-tooltip-content-inner::before {
        content: '';
        position: absolute;
        top: 2px;
        right: 20px;
        border-left: 6px solid transparent;
        border-right: 6px solid transparent;
        border-bottom: 6px solid #1e293b;
      }

      /* Streaming Section Styles */
      .section-streaming {
        display: flex;
        flex-direction: column;
        gap: 12px;
      }

      .streaming-header {
        display: flex;
        align-items: center;
        gap: 10px;
        padding: 8px 0;
      }

      .streaming-label {
        font-size: 13px;
        color: #64748b;
        font-weight: 500;
      }

      .streaming-content {
        background: #1e293b;
        border-radius: 8px;
        padding: 16px;
        max-height: 300px;
        overflow-y: auto;
        overflow-x: hidden;
        position: relative;
      }

      .streaming-content pre {
        margin: 0;
        white-space: pre-wrap;
        word-break: break-word;
      }

      .streaming-content code {
        font-family: 'SF Mono', 'Fira Code', 'JetBrains Mono', Consolas, monospace;
        font-size: 12px;
        line-height: 1.5;
        color: #94a3b8;
      }

      /* Blinking cursor effect at the end */
      .streaming-content::after {
        content: '|';
        color: #3b82f6;
        animation: cursorBlink 1s step-end infinite;
        font-family: monospace;
      }

      @keyframes cursorBlink {
        50% { opacity: 0; }
      }

      /* Scrollbar styling for dark container */
      .streaming-content::-webkit-scrollbar {
        width: 8px;
      }

      .streaming-content::-webkit-scrollbar-track {
        background: #334155;
        border-radius: 4px;
      }

      .streaming-content::-webkit-scrollbar-thumb {
        background: #475569;
        border-radius: 4px;
      }

      .streaming-content::-webkit-scrollbar-thumb:hover {
        background: #64748b;
      }

      .streaming-waiting {
        display: flex;
        justify-content: center;
        align-items: center;
        min-height: 100px;
        background: #f8fafc;
        border-radius: 8px;
        border: 1px dashed #e2e8f0;
      }

      /* Mobile responsiveness */
      @media (max-width: 768px) {
        .streaming-content {
          max-height: 200px;
          padding: 12px;
        }

        .streaming-content code {
          font-size: 11px;
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
                @docling_health,
                @locale,
                @timezone
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

      <%!-- Cloud GPU Status Message (when no running instance) --%>
      <%= if @can_manage_gpu? and show_gpu_no_instance_message?(@gpu_instance_status, @gpu_prompt_dismissed) do %>
        <% cloud_status = @gpu_instance_status[:cloud_status] || %{} %>
        <% is_available = cloud_status[:availability] == :available %>
        <div class={[
          "rounded-xl border px-5 py-4 flex items-center justify-between gap-4 shadow-sm",
          if(is_available,
            do: "border-blue-200 bg-gradient-to-r from-blue-50 to-indigo-50",
            else: "border-slate-200 bg-gradient-to-r from-slate-50 to-gray-50"
          )
        ]}>
          <div class="flex items-center gap-4">
            <div class={[
              "flex h-12 w-12 items-center justify-center rounded-full",
              if(is_available, do: "bg-blue-100 text-blue-600", else: "bg-slate-100 text-slate-500")
            ]}>
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
              <span class={[
                "text-sm font-semibold",
                if(is_available, do: "text-blue-900", else: "text-gray-900")
              ]}>
                <%= if is_available do %>
                  Cloud GPU Available
                <% else %>
                  {cloud_status[:message] || "No GPU Instance"}
                <% end %>
              </span>
              <span class={[
                "text-xs",
                if(is_available, do: "text-blue-700", else: "text-gray-600")
              ]}>
                <%= if is_available do %>
                  Will provision automatically on first upload (~3-5 min)
                <% else %>
                  {cloud_status[:detail] || "An administrator needs to configure cloud GPU access."}
                <% end %>
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

      <%= if @global_active_runs != [] do %>
        <section class="active-runs-widget">
          <div class="active-runs-header">
            <span class="active-runs-pulse"></span>
            <span class="active-runs-title">
              {length(@global_active_runs)} Active Report{if length(@global_active_runs) != 1,
                do: "s",
                else: ""}
            </span>
          </div>
          <div class="active-runs-list">
            <%= for run <- @global_active_runs do %>
              <div class={[
                "active-run-item",
                if(run.id == @current_run_id, do: "current-run", else: "")
              ]}>
                <div class="run-info">
                  <span class="run-patient">{patient_display_name(run.patient)}</span>
                  <span class="run-template">{(run.template && run.template.name) || "Report"}</span>
                </div>
                <div class="run-status-badge" data-status={run.status}>
                  {String.capitalize(run.status)}
                </div>
              </div>
            <% end %>
          </div>
        </section>
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
          <%= if Enum.any?(@debug_runs) do %>
            <form
              id="report-run-switcher"
              phx-change="select_debug_run"
              class="flex items-center gap-2"
            >
              <label class="text-xs font-medium text-slate-600">Report run</label>
              <select
                name="run-id"
                class="select select-sm w-64 bg-white text-slate-900 border-slate-300"
              >
                <%= for run <- @debug_runs do %>
                  <option value={run.id} selected={run.id == @visible_run_id}>
                    {String.capitalize(run.run_type || "full")} · {String.capitalize(
                      run.status || "pending"
                    )} · {format_timestamp(run.inserted_at, @locale, @timezone)}
                  </option>
                <% end %>
              </select>
            </form>
          <% end %>
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
          <%= if MapSet.size(@running_sections) > 0 do %>
            <div class="flex items-center gap-2">
              <div class="run-progress-indicator">
                <span class="progress-pulse"></span>
                <span class="progress-text">
                  {completed_section_count(@sections)}/{length(@sections)} sections
                </span>
              </div>
              <%= if @current_run_id do %>
                <button
                  type="button"
                  class="rounded-full bg-red-500 hover:bg-red-600 text-white px-2 py-1 text-xs font-medium shadow-sm transition-colors"
                  phx-click="cancel_report_run"
                  phx-value-run-id={@current_run_id}
                  data-confirm="Are you sure you want to cancel this report? This will stop all pending sections."
                  title="Cancel report run"
                >
                  ✕
                </button>
              <% end %>
            </div>
          <% else %>
            <button
              class="btn btn-primary"
              phx-click="run_full_report"
            >
              Run All Sections
            </button>
          <% end %>
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
                <%= cond do %>
                  <% @fast_available? == nil -> %>
                    <%!-- Still checking - show subtle indicator --%>
                    <span class="text-slate-400 text-xs">Checking...</span>
                  <% @fast_available? == false -> %>
                    <%!-- Unavailable - keep it simple, disabled button is self-explanatory --%>
                    <%= cond do %>
                      <% @fast_unavailable_reason && String.contains?(@fast_unavailable_reason || "", "starting") -> %>
                        <span class="text-sky-600 text-xs">Starting up...</span>
                      <% @fast_unavailable_reason && String.contains?(@fast_unavailable_reason || "", "loading") -> %>
                        <span class="text-sky-600 text-xs">Loading...</span>
                      <% true -> %>
                        <%!-- Don't show anything - grayed out button is enough --%>
                    <% end %>
                  <% true -> %>
                    <%!-- Available (true) - show nothing --%>
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
                class="btn btn-outline btn-sm w-full text-slate-700 border-slate-300 bg-white hover:bg-slate-100 hover:text-slate-900 hover:border-slate-400"
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
            <%= if @upload_blocked_reason do %>
              <div class="text-xs text-rose-600 bg-rose-50 border border-rose-200 rounded-lg px-3 py-2 flex items-start gap-2">
                <span aria-hidden="true">⚠️</span>
                <span>{@upload_blocked_reason}</span>
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
                        backend_badge_class(doc, doc.backend_status)
                      ]}
                      title={backend_badge_title(doc.backend_status)}
                    >
                      {backend_label(doc)}
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
                <%= if show_progress_bar?(doc) do %>
                  <div style="margin-top: 8px;">
                    <%= if is_map(doc.progress) && map_size(doc.progress) > 0 && doc.progress["stages"] && is_map(doc.progress["stages"]) && map_size(doc.progress["stages"]) > 0 do %>
                      <.progress_stages progress={doc.progress} compact={true} />
                    <% else %>
                      <div style="height: 6px; background: #e2e8f0; border-radius: 999px; overflow: hidden;">
                        <div style={"height: 6px; background: #3b82f6; border-radius: 999px; width: #{(doc.ingestion_progress || 0) / 1.0}%; transition: width 200ms ease;"}>
                        </div>
                      </div>
                      <div style="display: flex; justify-content: space-between; font-size: 10px; color: #94a3b8; margin-top: 4px;">
                        <span>{String.capitalize(doc.ingestion_stage || "processing")}</span>
                        <span>
                          {:erlang.float_to_binary((doc.ingestion_progress || 0) / 1, decimals: 2)}%
                        </span>
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
                  <strong>
                    {format_timestamp(@selected_document.uploaded_at, @locale, @timezone)}
                  </strong>
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
                    {backend_label(@selected_document)}
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
                    <strong>
                      {format_timestamp(@selected_document.ingested_at, @locale, @timezone)}
                    </strong>
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

              <%= if @selected_document.cleaned_truncated? do %>
                <div class="text-[11px] text-amber-600">
                  Showing first {format_byte_size(@selected_document.cleaned_limit)} of cleaned
                  markdown. Open the document for full context.
                </div>
              <% end %>
              <div style="font-size: 12px; color: #475569; white-space: pre-line; max-height: 200px; overflow-y: auto; border: 1px solid #e2e8f0; border-radius: 12px; padding: 12px; background: #fdfefe;">
                {@selected_document.cleaned_content ||
                  "This PDF is still being ingested. It will appear here when markdown is ready."}
              </div>
            </div>
          <% end %>
        </aside>

        <section class="section-grid">
          <%= for section_entry <- @visible_sections do %>
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
                  <%= if section_entry.section && section_entry.section.prompt_template do %>
                    <div class="prompt-tooltip-wrapper">
                      <button type="button" class="prompt-tooltip-btn">
                        <svg
                          xmlns="http://www.w3.org/2000/svg"
                          width="14"
                          height="14"
                          viewBox="0 0 24 24"
                          fill="none"
                          stroke="currentColor"
                          stroke-width="2"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                        >
                          <path d="M14.5 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7.5L14.5 2z" />
                          <polyline points="14 2 14 8 20 8" />
                          <line x1="16" y1="13" x2="8" y2="13" />
                          <line x1="16" y1="17" x2="8" y2="17" />
                          <line x1="10" y1="9" x2="8" y2="9" />
                        </svg>
                        Prompt
                      </button>
                      <div class="prompt-tooltip-content">
                        <div class="prompt-tooltip-content-inner">
                          {section_entry.section.prompt_template}
                        </div>
                      </div>
                    </div>
                  <% end %>
                  <button
                    class={[
                      "btn btn-outline btn-sm border border-slate-300 text-slate-700 bg-white",
                      "hover:bg-slate-100 hover:text-slate-900 transition-colors"
                    ]}
                    phx-click="run_section"
                    phx-value-section-id={section_entry.section.id}
                    disabled={MapSet.member?(@running_sections, to_string(section_entry.section.id))}
                  >
                    <%= if MapSet.member?(@running_sections, to_string(section_entry.section.id)) do %>
                      Running…
                    <% else %>
                      Run Section
                    <% end %>
                  </button>
                </div>
              </header>

              <%= if MapSet.member?(@running_sections, to_string(section_entry.section.id)) do %>
                <div class="section-output section-streaming">
                  <div class="streaming-header">
                    <span class="loading loading-spinner loading-md text-slate-400"></span>
                    <span class="streaming-label">{streaming_status_label(section_entry)}</span>
                  </div>

                  <%= if Map.has_key?(@streaming_content, to_string(section_entry.section.id)) do %>
                    <div
                      class="streaming-content"
                      id={"streaming-#{section_entry.section.id}"}
                      phx-hook="StreamingScroll"
                    >
                      <pre><code>{Map.get(@streaming_content, to_string(section_entry.section.id), "")}</code></pre>
                    </div>
                  <% else %>
                    <div class="streaming-waiting">
                      <span class="text-slate-400 text-sm">
                        {streaming_waiting_label(section_entry)}
                      </span>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <div class="section-output">
                  <%= if section_entry.last_run do %>
                    <div style="margin-bottom: 12px; font-size: 12px; color: #94a3b8;">
                      Updated {format_timestamp(section_entry.last_run.updated_at, @locale, @timezone)}
                    </div>
                    <Markdown.markdown
                      content={section_entry.last_run.output_markdown}
                      fallback="Awaiting output"
                      class="report-markdown"
                      inline_citations={section_entry.last_run.inline_citations}
                      section_id={section_entry.section.id}
                    />
                  <% else %>
                    <div style="font-size: 13px; color: #94a3b8;">
                      No output generated yet. Run this section to produce the initial draft.
                    </div>
                  <% end %>
                </div>

                <%= if section_entry.last_run &&
                        Enum.any?(section_citation_docs(section_entry.last_run, @documents)) do %>
                  <div class="citations">
                    <%= for citation <- section_citation_docs(section_entry.last_run, @documents) do %>
                      <%= if citation.document_id do %>
                        <button
                          type="button"
                          phx-click="open_document_modal"
                          phx-value-doc-id={citation.document_id}
                          phx-value-ranges={encode_ranges(citation.ranges)}
                          phx-value-section-id={section_entry.section.id}
                        >
                          {citation.label}
                        </button>
                      <% else %>
                        <span>{citation.label}</span>
                      <% end %>
                    <% end %>
                  </div>
                <% end %>
              <% end %>
            </article>
          <% end %>
        </section>
      </div>

      <%!-- Debug Panel: Report Run Inspector --%>
      <div class="debug-panel">
        <div class="debug-header">
          <h3>
            <svg
              xmlns="http://www.w3.org/2000/svg"
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M12 20h9" /><path d="M16.376 3.622a1 1 0 0 1 3.002 3.002L7.368 18.635a2 2 0 0 1-.855.506l-2.872.838a.5.5 0 0 1-.62-.62l.838-2.872a2 2 0 0 1 .506-.854z" /><path d="m15 5 3 3" />
            </svg>
            Report Run Inspector
          </h3>
          <div class="flex items-center gap-3">
            <%= if Enum.any?(@debug_runs) do %>
              <form phx-change="select_debug_run">
                <select name="run-id" class="debug-select">
                  <%= for run <- @debug_runs do %>
                    <option value={run.id} selected={run.id == @debug_selected_run_id}>
                      {String.capitalize(run.run_type || "full")} run · {String.capitalize(
                        run.status || "pending"
                      )} · {format_timestamp(run.inserted_at, @locale, @timezone)}
                    </option>
                  <% end %>
                </select>
              </form>
            <% end %>

            <%= if @debug_selected_run && Enum.any?(@debug_selected_run.section_runs || []) do %>
              <div class="flex items-center gap-2">
                <button
                  type="button"
                  class="btn btn-ghost btn-xs border border-slate-200 text-slate-700"
                  phx-click="toggle_debug_sections_all"
                  phx-value-action="expand"
                >
                  Expand all
                </button>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs border border-slate-200 text-slate-700"
                  phx-click="toggle_debug_sections_all"
                  phx-value-action="collapse"
                >
                  Collapse all
                </button>
              </div>
            <% end %>
          </div>
        </div>

        <%= if @debug_selected_run do %>
          <div class="debug-run-meta">
            <div class="debug-meta-item">
              <span class="debug-meta-label">Status</span>
              <span class="debug-meta-value">
                {String.capitalize(@debug_selected_run.status || "pending")}
              </span>
            </div>
            <div class="debug-meta-item">
              <span class="debug-meta-label">Type</span>
              <span class="debug-meta-value">
                {String.capitalize(@debug_selected_run.run_type || "full")}
              </span>
            </div>
            <div class="debug-meta-item">
              <span class="debug-meta-label">Run ID</span>
              <span class="debug-meta-value" style="font-size: 11px; font-family: monospace;">
                {@debug_selected_run.id}
              </span>
            </div>
            <div class="debug-meta-item">
              <span class="debug-meta-label">Template</span>
              <span class="debug-meta-value">
                {(@debug_selected_run.template && @debug_selected_run.template.name) || "—"}
              </span>
            </div>
            <div class="debug-meta-item">
              <span class="debug-meta-label">Patient</span>
              <span class="debug-meta-value">
                {(@debug_selected_run.patient && @debug_selected_run.patient.patient_key) ||
                  (@debug_selected_run.patient && @debug_selected_run.patient.id) || "—"}
              </span>
            </div>
            <div class="debug-meta-item">
              <span class="debug-meta-label">Record Set</span>
              <span class="debug-meta-value">
                {@debug_selected_run.record_set_id || "—"}
              </span>
            </div>
            <div class="debug-meta-item">
              <span class="debug-meta-label">Triggered By</span>
              <span class="debug-meta-value">
                {(@debug_selected_run.triggered_by && @debug_selected_run.triggered_by.email) || "—"}
              </span>
            </div>
            <div class="debug-meta-item">
              <span class="debug-meta-label">Started</span>
              <span class="debug-meta-value">
                {format_timestamp(@debug_selected_run.started_at, @locale, @timezone)}
              </span>
            </div>
            <div class="debug-meta-item">
              <span class="debug-meta-label">Finished</span>
              <span class="debug-meta-value">
                {format_timestamp(@debug_selected_run.finished_at, @locale, @timezone)}
              </span>
            </div>
            <%= if @debug_selected_run.cached_content_name do %>
              <div class="debug-meta-item">
                <span class="debug-meta-label">Cache</span>
                <span class="debug-meta-value" style="font-size: 11px; font-family: monospace;">
                  {String.slice(@debug_selected_run.cached_content_name || "", -20, 20)}...
                </span>
              </div>
            <% end %>
            <%= if @debug_selected_run.summary_invocation do %>
              <div class="debug-meta-item">
                <span class="debug-meta-label">Summary Invocation</span>
                <span class="debug-meta-value" style="font-size: 11px; font-family: monospace;">
                  {@debug_selected_run.summary_invocation.id} ({String.capitalize(
                    @debug_selected_run.summary_invocation.status || "pending"
                  )})
                </span>
              </div>
            <% end %>
          </div>

          <div class="debug-sections">
            <%= for section_run <- Enum.sort_by(@debug_selected_run.section_runs || [], & &1.section_template && &1.section_template.position) do %>
              <% expanded? = MapSet.member?(@debug_expanded_sections, to_string(section_run.id)) %>
              <div class="debug-section">
                <button
                  type="button"
                  class="debug-section-header"
                  phx-click="toggle_debug_section"
                  phx-value-section-id={section_run.id}
                >
                  <span class="debug-section-title">
                    {(section_run.section_template && section_run.section_template.title) ||
                      "Unknown Section"}
                  </span>
                  <span class="debug-section-status" data-status={section_run.status}>
                    {String.capitalize(section_run.status || "pending")}
                  </span>
                  <svg
                    class={"debug-chevron #{if expanded?, do: "expanded"}"}
                    xmlns="http://www.w3.org/2000/svg"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  >
                    <path d="m6 9 6 6 6-6" />
                  </svg>
                </button>

                <%= if expanded? do %>
                  <div class="debug-section-content">
                    <%!-- Schema Definition --%>
                    <%= if section_run.section_template && section_run.section_template.output_schema && map_size(section_run.section_template.output_schema) > 0 do %>
                      <div class="debug-block">
                        <div class="debug-block-header">
                          <span>Output Schema</span>
                          <span class="debug-block-badge">JSON Schema</span>
                        </div>
                        <div class="debug-block-content json">
                          {Jason.encode!(section_run.section_template.output_schema, pretty: true)}
                        </div>
                      </div>
                    <% end %>

                    <%!-- Prompt Template --%>
                    <%= if section_run.section_template && section_run.section_template.prompt_template do %>
                      <div class="debug-block">
                        <div class="debug-block-header">
                          <span>Prompt Template</span>
                          <span class="debug-block-badge">EEx</span>
                        </div>
                        <div class="debug-block-content">
                          {section_run.section_template.prompt_template}
                        </div>
                      </div>
                    <% end %>

                    <%!-- LLM Invocation Details --%>
                    <%= if section_run.llm_invocation do %>
                      <% inv = section_run.llm_invocation %>

                      <%!-- Model & Config --%>
                      <div class="debug-block">
                        <div class="debug-block-header">
                          <span>LLM Configuration</span>
                          <span class="debug-block-badge">{inv.provider}/{inv.model}</span>
                        </div>
                        <div class="debug-usage-grid">
                          <div class="debug-usage-item">
                            <div class="debug-usage-value">{inv.temperature || "—"}</div>
                            <div class="debug-usage-label">Temperature</div>
                          </div>
                          <div class="debug-usage-item">
                            <div class="debug-usage-value">{inv.max_output_tokens || "—"}</div>
                            <div class="debug-usage-label">Max Tokens</div>
                          </div>
                          <div class="debug-usage-item">
                            <div class="debug-usage-value">{inv.req_duration_ms || "—"}ms</div>
                            <div class="debug-usage-label">Duration</div>
                          </div>
                          <div class="debug-usage-item">
                            <div class="debug-usage-value">
                              {String.capitalize(inv.status || "pending")}
                            </div>
                            <div class="debug-usage-label">Status</div>
                          </div>
                        </div>
                      </div>

                      <%!-- Token Usage --%>
                      <%= if inv.usage && map_size(inv.usage) > 0 do %>
                        <div class="debug-block">
                          <div class="debug-block-header">
                            <span>Token Usage</span>
                          </div>
                          <div class="debug-usage-grid">
                            <div class="debug-usage-item">
                              <div class="debug-usage-value">
                                {format_token_count(
                                  inv.usage["input_tokens"] || inv.usage["promptTokenCount"]
                                )}
                              </div>
                              <div class="debug-usage-label">Input</div>
                            </div>
                            <div class="debug-usage-item">
                              <div class="debug-usage-value">
                                {format_token_count(
                                  inv.usage["output_tokens"] || inv.usage["candidatesTokenCount"]
                                )}
                              </div>
                              <div class="debug-usage-label">Output</div>
                            </div>
                            <%= if inv.usage["cachedContentTokenCount"] || inv.usage["cache_read_input_tokens"] do %>
                              <div class="debug-usage-item">
                                <div class="debug-usage-value">
                                  {format_token_count(
                                    inv.usage["cachedContentTokenCount"] ||
                                      inv.usage["cache_read_input_tokens"]
                                  )}
                                </div>
                                <div class="debug-usage-label">Cached</div>
                              </div>
                            <% end %>
                            <div class="debug-usage-item">
                              <div class="debug-usage-value">
                                {format_token_count(inv.usage["totalTokenCount"])}
                              </div>
                              <div class="debug-usage-label">Total</div>
                            </div>
                          </div>
                        </div>
                      <% end %>

                      <%!-- Rendered Prompt --%>
                      <%= if inv.prompt_text do %>
                        <div class="debug-block">
                          <div class="debug-block-header">
                            <span>Rendered Prompt</span>
                            <span class="debug-block-badge">
                              {String.length(inv.prompt_text)} chars
                            </span>
                          </div>
                          <div class="debug-block-content">{inv.prompt_text}</div>
                        </div>
                      <% end %>

                      <%!-- Prompt Context --%>
                      <%= if inv.prompt_context && map_size(inv.prompt_context) > 0 do %>
                        <div class="debug-block">
                          <div class="debug-block-header">
                            <span>Prompt Context</span>
                            <span class="debug-block-badge">JSON</span>
                          </div>
                          <div class="debug-block-content json">
                            {Jason.encode!(inv.prompt_context, pretty: true)}
                          </div>
                        </div>
                      <% end %>

                      <%!-- Response Text --%>
                      <%= if inv.response_text do %>
                        <div class="debug-block">
                          <div class="debug-block-header">
                            <span>Response Text</span>
                            <span class="debug-block-badge">
                              {String.length(inv.response_text)} chars
                            </span>
                          </div>
                          <div class="debug-block-content">{inv.response_text}</div>
                        </div>
                      <% end %>

                      <%!-- Response Object --%>
                      <%= if inv.response_object && map_size(inv.response_object) > 0 do %>
                        <div class="debug-block">
                          <div class="debug-block-header">
                            <span>Response Object</span>
                            <span class="debug-block-badge">JSON</span>
                          </div>
                          <div class="debug-block-content json">
                            {Jason.encode!(inv.response_object, pretty: true)}
                          </div>
                        </div>
                      <% end %>

                      <%!-- Persisted Citations --%>
                      <%= if section_run.citations && section_run.citations != [] do %>
                        <div class="debug-block">
                          <div class="debug-block-header">
                            <span>Persisted Citations</span>
                            <span class="debug-block-badge">report_section_citations</span>
                          </div>
                          <div class="debug-block-content">
                            <%= for cite <- section_run.citations do %>
                              <div class="debug-citation-row">
                                <span class="debug-citation-chip">
                                  {cite.citation_label || "—"}
                                </span>
                                <span class="debug-citation-chip">
                                  Doc: {cite.document_id || "—"}
                                </span>
                                <span class="debug-citation-chip">
                                  Lines: {format_line_range(
                                    get_in(cite.source_span || %{}, ["line_start"]),
                                    get_in(cite.source_span || %{}, ["line_end"])
                                  )}
                                </span>
                                <%= if chunk_id = get_in(cite.source_span || %{}, ["chunk_id"]) do %>
                                  <span class="debug-citation-chip">
                                    Chunk: {chunk_id}
                                  </span>
                                <% end %>
                                <%= if excerpt = get_in(cite.source_span || %{}, ["excerpt"]) do %>
                                  <span class="debug-citation-excerpt">
                                    {String.slice(excerpt, 0, 160)}
                                  </span>
                                <% end %>
                              </div>
                            <% end %>
                          </div>
                        </div>
                      <% end %>

                      <%!-- Error --%>
                      <%= if inv.error do %>
                        <div class="debug-block">
                          <div class="debug-block-header">
                            <span>Error</span>
                          </div>
                          <div class="debug-block-content debug-error-content">
                            {Jason.encode!(inv.error, pretty: true)}
                          </div>
                        </div>
                      <% end %>
                    <% else %>
                      <div class="debug-empty">
                        No LLM invocation recorded for this section run.
                      </div>
                    <% end %>

                    <%!-- Section Run Output --%>
                    <%= if section_run.output_markdown do %>
                      <div class="debug-block">
                        <div class="debug-block-header">
                          <span>Output Markdown</span>
                          <%= if section_run.confidence_score do %>
                            <span class="debug-block-badge">
                              Confidence: {Float.round(section_run.confidence_score * 100, 1)}%
                            </span>
                          <% end %>
                        </div>
                        <div class="debug-block-content">{section_run.output_markdown}</div>
                      </div>
                    <% end %>

                    <%!-- Section Output Object --%>
                    <%= if section_run.output_object && map_size(section_run.output_object) > 0 do %>
                      <div class="debug-block">
                        <div class="debug-block-header">
                          <span>Output Object</span>
                          <span class="debug-block-badge">JSON</span>
                        </div>
                        <div class="debug-block-content json">
                          {Jason.encode!(section_run.output_object, pretty: true)}
                        </div>
                      </div>
                    <% end %>

                    <%!-- Section Run Error --%>
                    <%= if section_run.error do %>
                      <div class="debug-block">
                        <div class="debug-block-header">
                          <span>Section Error</span>
                        </div>
                        <div class="debug-block-content debug-error-content">
                          {Jason.encode!(section_run.error, pretty: true)}
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <%= if @debug_selected_run && Enum.any?(@debug_selected_run.section_runs || []) do %>
            <div class="debug-footer-actions">
              <button
                type="button"
                class="btn btn-ghost btn-xs border border-slate-200"
                phx-click="toggle_debug_sections_all"
                phx-value-action="expand"
              >
                Expand all
              </button>
              <button
                type="button"
                class="btn btn-ghost btn-xs border border-slate-200"
                phx-click="toggle_debug_sections_all"
                phx-value-action="collapse"
              >
                Collapse all
              </button>
            </div>
          <% end %>
        <% else %>
          <div class="debug-empty">
            No report runs yet for this workspace. Run a report to see execution details here.
          </div>
        <% end %>
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
                Uploaded {format_timestamp(@document_modal_document.uploaded_at, @locale, @timezone)} • {@document_modal_document.filename}
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

          <%= if @document_modal_focus do %>
            <div class="document-focus">
              <div class="document-focus-header">
                Reference {format_line_range(
                  @document_modal_focus.line_start,
                  @document_modal_focus.line_end
                )}
              </div>
              <div class="document-focus-lines">
                <%= for line <- @document_modal_focus.lines do %>
                  <div class={["focus-line", line.highlight && "active"]}>
                    <span class="focus-line-number">L{pad_line(line.number)}</span>
                    <pre>{line.text}</pre>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @document_modal_section do %>
            <div class="document-section-snippet">
              <h4>Report section</h4>
              <div class="snippet-text">
                <strong>{@document_modal_section.title || "Section"}</strong>
                <%= if @document_modal_section.excerpt do %>
                  — {@document_modal_section.excerpt}
                <% end %>
              </div>
            </div>
          <% end %>

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
                  <%= if @document_modal_document.summary_truncated? do %>
                    <div class="text-xs text-amber-600 mb-2">
                      Preview truncated to {format_byte_size(@document_modal_document.summary_limit)}.
                    </div>
                  <% end %>
                  {@document_modal_document.summary ||
                    "Summary not available yet. Once the ingestion pipeline completes, an overview of this PDF will appear here."}
                </div>
              <% "cleaned" -> %>
                <%= if @document_modal_document.cleaned_truncated? do %>
                  <div class="text-xs text-amber-600 mb-2">
                    Showing first {format_byte_size(@document_modal_document.cleaned_limit)} of
                    the document text.
                  </div>
                <% end %>
                <pre>{@document_modal_document.cleaned_content ||
      "Cleaned markdown will be available when ingestion completes."}</pre>
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
                  <.link navigate={~p"/admin/llm-config"} class="btn btn-ghost btn-xs">
                    LLM Config
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
                            {run_timestamp_label(run, @locale, @timezone)}
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
                      +{length(@template.sections) - 4} additional sections configured in LLM Config.
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
                        Updated {format_timestamp(set.updated_at, @locale, @timezone)}
                      </div>
                      <div class="workspace-run-meta">
                        <%= if run = Map.get(@record_set_latest_runs, set.id) do %>
                          <span>
                            {String.capitalize(run.run_type || "full")} · {run_status_label(run)}
                          </span>
                          <span>{format_timestamp(run_timestamp(run), @locale, @timezone)}</span>
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

  defp mathjax_head(assigns \\ %{}) do
    ~H"""
    <script
      id="mathjax-script"
      defer
      src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js"
    >
    </script>
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

  defp run_timestamp_label(run, locale, timezone) do
    case run_timestamp(run) do
      nil -> "Updated recently"
      dt -> "Updated #{format_timestamp(dt, locale, timezone)}"
    end
  end

  defp prompt_excerpt(nil), do: "Ingestion prompt not yet configured."

  defp prompt_excerpt(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> truncate(260)
  end

  defp section_excerpt(nil), do: nil

  defp section_excerpt(text) when is_binary(text) do
    text
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.trim()
    |> truncate(240)
  end

  defp patient_name(nil), do: "Patient"
  defp patient_name(%{current_profile: %Ecto.Association.NotLoaded{}}), do: "Patient"
  defp patient_name(%{current_profile: nil}), do: "Patient"

  defp patient_name(%{current_profile: profile}) do
    Enum.filter([profile.given_name, profile.family_name], & &1)
    |> Enum.join(" ")
  end

  defp patient_display_name(nil), do: "Patient"

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

  defp patient_mrn(nil), do: "N/A"
  defp patient_mrn(%{current_profile: nil}), do: "N/A"
  defp patient_mrn(%{current_profile: profile}), do: profile.mrn || "N/A"

  defp patient_dob(nil), do: "N/A"
  defp patient_dob(%{current_profile: nil}), do: "N/A"

  defp patient_dob(%{current_profile: profile}) do
    profile.date_of_birth || "N/A"
  end

  defp status_label(%{last_run: nil}), do: "Not generated"
  defp status_label(%{last_run: %{status: "completed"}}), do: "Ready"
  defp status_label(%{last_run: %{status: "queued"}}), do: "Queued"
  defp status_label(%{last_run: %{status: "running"}}), do: "Running"
  defp status_label(%{last_run: %{status: "error"}}), do: "Error"
  defp status_label(%{last_run: %{status: "failed"}}), do: "Failed"
  defp status_label(%{last_run: %{status: status}}), do: status

  # Streaming status labels - shown in the spinner header
  defp streaming_status_label(%{status: status}) when status in ["pending", "queued"],
    do: "Queued..."

  defp streaming_status_label(%{status: "running"}), do: "Generating..."
  defp streaming_status_label(%{status: "error"}), do: "Retrying..."
  defp streaming_status_label(_), do: "Processing..."

  # Streaming waiting labels - shown when no content yet
  defp streaming_waiting_label(%{status: status}) when status in ["pending", "queued"],
    do: "Waiting in queue..."

  defp streaming_waiting_label(%{status: "running"}), do: "Waiting for response..."
  defp streaming_waiting_label(%{status: "error"}), do: "Attempting retry..."
  defp streaming_waiting_label(_), do: "Waiting..."

  # Helper to find section_id from section_run_id
  defp find_section_id_for_run(socket, section_run_id) do
    socket.assigns.sections
    |> Enum.find_value(fn entry ->
      if entry.last_run && to_string(entry.last_run.id) == to_string(section_run_id) do
        to_string(entry.section.id)
      end
    end)
  end

  defp completed_section_count(sections) do
    Enum.count(sections, fn entry ->
      entry.status == "completed"
    end)
  end
end
