defmodule MedlumWeb.ReportsLive.DocumentHandlers do
  @moduledoc """
  Handles document-related events for the ReportsLive LiveView.

  This module contains all event handlers and helper functions related to
  document selection, display, and management operations.
  """

  alias Medlum.Documents
  alias Medlum.Reports
  alias Phoenix.LiveView
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

  @doc """
  Handles the "select_document" event.
  Selects or deselects a document in the sidebar.
  """
  def handle_select_document(%{"doc-id" => doc_id}, socket) do
    current = socket.assigns.selected_document
    doc = find_document_by_id(socket.assigns.documents, doc_id)

    cond do
      is_nil(doc) ->
        {:noreply, socket}

      current && current.id == doc.id ->
        {:noreply, Phoenix.Component.assign(socket, selected_document: nil)}

      true ->
        hydrated = maybe_hydrate_selected_document(doc)
        {:noreply, Phoenix.Component.assign(socket, selected_document: hydrated)}
    end
  end

  @doc """
  Handles the "clear_document" event.
  Clears the currently selected document.
  """
  def handle_clear_document(_params, socket) do
    {:noreply, Phoenix.Component.assign(socket, selected_document: nil)}
  end

  @doc """
  Handles the "open_document_modal" event.
  Opens the document modal with the specified document and optional focus context.
  """
  def handle_open_document_modal(%{"doc-id" => doc_id} = params, socket) do
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
         LiveView.put_flash(
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
         |> Phoenix.Component.assign(:document_modal_document, doc_with_content)
         |> Phoenix.Component.assign(:document_modal_section, section_context)
         |> Phoenix.Component.assign(:document_modal_focus, focus)
         |> Phoenix.Component.assign(
           :document_modal_tab,
           if(focus, do: "cleaned", else: "summary")
         )
         |> Phoenix.Component.assign(:document_modal_open, true)}
    end
  end

  @doc """
  Handles the "close_document_modal" event.
  Closes the document modal and clears its state.
  """
  def handle_close_document_modal(_params, socket) do
    {:noreply,
     socket
     |> Phoenix.Component.assign(:document_modal_document, nil)
     |> Phoenix.Component.assign(:document_modal_focus, nil)
     |> Phoenix.Component.assign(:document_modal_section, nil)
     |> Phoenix.Component.assign(:document_modal_tab, "summary")
     |> Phoenix.Component.assign(:document_modal_open, false)}
  end

  @doc """
  Handles the "switch_document_modal_tab" event.
  Switches between tabs in the document modal (summary/full document).
  """
  def handle_switch_document_modal_tab(%{"tab" => tab}, socket) do
    tab = to_string(tab)

    if tab in @document_modal_tab_ids do
      {:noreply, Phoenix.Component.assign(socket, :document_modal_tab, tab)}
    else
      {:noreply, socket}
    end
  end

  @doc """
  Handles the "delete_document" event.
  Deletes a document from the workspace.
  """
  def handle_delete_document(%{"doc-id" => doc_id}, socket) do
    scope = socket.assigns.current_scope

    case Documents.delete_upload(scope, doc_id) do
      :ok ->
        # Need to call load_workspace from the parent module
        {:noreply,
         socket
         |> Phoenix.Component.assign(:selected_document, nil)
         |> LiveView.put_flash(:info, "Document removed.")
         |> Phoenix.Component.assign(:needs_workspace_reload, true)}

      {:error, :not_found} ->
        {:noreply, LiveView.put_flash(socket, :error, "Document no longer exists.")}
    end
  end

  @doc """
  Handles the "retry_ingestion" event.
  Retries the ingestion process for a failed document.
  """
  def handle_retry_ingestion(%{"doc-id" => doc_id}, socket) do
    template = socket.assigns.template

    case find_document_by_id(socket.assigns.documents, doc_id) do
      nil ->
        {:noreply, LiveView.put_flash(socket, :error, "Document no longer exists.")}

      doc ->
        case Documents.retry_ingestion(doc.id,
               template: template,
               backend: socket.assigns.docling_backend
             ) do
          {:ok, _job} ->
            {:noreply,
             socket
             |> LiveView.put_flash(:info, "Retry queued for #{doc.label}.")
             |> Phoenix.Component.assign(:needs_workspace_reload, true)}

          {:error, :template_required} ->
            {:noreply,
             socket
             |> LiveView.put_flash(:error, "A template is required to retry ingestion.")}

          {:error, reason} ->
            {:noreply, LiveView.put_flash(socket, :error, "Unable to retry: #{inspect(reason)}")}
        end
    end
  end

  @doc """
  Hydrates a selected document with its content if not already loaded.
  """
  def maybe_hydrate_selected_document(doc) do
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

  @doc """
  Refreshes the document modal if it's open and the document still exists.
  """
  def maybe_refresh_document_modal(%{assigns: assigns} = socket) do
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
            |> Phoenix.Component.assign(:document_modal_document, nil)
            |> Phoenix.Component.assign(:document_modal_open, false)

          doc ->
            Phoenix.Component.assign(socket, :document_modal_document, doc)
        end
    end
  end

  @doc """
  Finds a document by its ID, sequence number, or mock_id.
  """
  def find_document_by_id(documents, doc_id) do
    doc_id = to_string(doc_id)

    # First try to find by actual document ID (UUID)
    # Then try to find by sequence number (e.g., "101" for doc-101)
    # Finally try to find by mock_id (e.g., "doc-101")
    Enum.find(documents, &(to_string(&1.id) == doc_id)) ||
      Enum.find(documents, &(to_string(&1.sequence) == doc_id)) ||
      Enum.find(documents, &(&1.mock_id && to_string(&1.mock_id) == doc_id))
  end

  @doc """
  Builds focus context for highlighting specific lines in a document.
  """
  def build_focus_context(_content, ranges) when ranges == [] or is_nil(ranges), do: nil

  def build_focus_context(content, ranges) when is_list(ranges) do
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

  @doc """
  Builds section context for displaying which section referenced a document.
  """
  def build_section_context(_sections, nil), do: nil

  def build_section_context(sections, section_id) when is_list(sections) do
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

  def build_section_context(_sections, _), do: nil

  # Private helper functions

  defp document_parsed?(doc) do
    doc.ingestion_stage == "completed" or doc.status == "parsed"
  end

  defp section_excerpt(text) when is_binary(text) do
    text
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.trim()
    |> truncate(240)
  end

  defp truncate(text, limit) do
    if String.length(text) <= limit do
      text
    else
      String.slice(text, 0, limit) <> "…"
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_ranges(nil), do: []
  defp parse_ranges(""), do: []

  defp parse_ranges(ranges) when is_binary(ranges) do
    ranges
    |> String.split(";", trim: true)
    |> Enum.map(fn part ->
      case String.split(part, "-", parts: 2) do
        [single] ->
          with {s, _} <- Integer.parse(single) do
            {s, s}
          else
            _ -> nil
          end

        [s, e] ->
          with {start, _} <- Integer.parse(s),
               {endv, _} <- Integer.parse(e) do
            {start, max(endv, start)}
          else
            _ -> nil
          end
      end
    end)
    |> Enum.filter(& &1)
  end

  defp parse_ranges(_), do: []

  defp normalize_ranges(line_start, line_end, ranges_param) do
    parsed = parse_ranges(ranges_param)

    cond do
      parsed != [] ->
        parsed

      is_integer(line_start) ->
        [{line_start, line_end || line_start}]

      true ->
        []
    end
  end
end
