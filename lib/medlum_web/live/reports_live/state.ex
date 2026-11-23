defmodule MedlumWeb.ReportsLive.State do
  @moduledoc """
  State transition functions for ReportsLive.

  All section state changes should go through here to ensure consistency
  between `@sections`, `@running_sections`, `@streaming_content`, and
  `@visible_sections`.
  """

  import Phoenix.Component, only: [assign: 3, update: 3]

  alias MedlumWeb.ReportsLive.SectionHelpers

  @max_streaming_length 50_000

  @doc """
  Mark sections as starting (about to begin execution).

  Updates:
  - `@running_sections` - Adds section IDs to running set
  - `@sections` - Sets status to "queued"
  - `@visible_sections` - Sets status to "queued" (keeps in sync)
  """
  def start_sections(socket, section_ids) do
    id_set = SectionHelpers.ids_to_set(section_ids)

    socket
    |> update(:running_sections, &MapSet.union(&1, id_set))
    |> update(:sections, fn sections ->
      Enum.map(sections, fn entry ->
        if SectionHelpers.in_set?(entry, id_set) do
          %{entry | status: "queued"}
        else
          entry
        end
      end)
    end)
    |> update(:visible_sections, fn sections ->
      Enum.map(sections, fn entry ->
        if SectionHelpers.in_set?(entry, id_set) do
          update_entry_status(entry, "queued")
        else
          entry
        end
      end)
    end)
  end

  @doc """
  Mark a section as complete with result.

  Updates:
  - `@running_sections` - Removes section ID
  - `@streaming_content` - Removes streaming content
  - `@sections` - Updates status and last_run
  - `@visible_sections` - Updates status
  """
  def complete_section(socket, section_id, result) do
    sid = to_string(section_id)
    status = if Map.get(result, :success, true), do: "completed", else: "error"

    socket
    |> update(:running_sections, &MapSet.delete(&1, sid))
    |> update(:streaming_content, &Map.delete(&1, sid))
    |> update(:sections, fn sections ->
      Enum.map(sections, fn entry ->
        if SectionHelpers.section_id(entry) == sid do
          entry
          |> Map.put(:status, status)
          |> maybe_put(:last_run, Map.get(result, :run))
          |> maybe_put(:error, Map.get(result, :error))
        else
          entry
        end
      end)
    end)
    |> update(:visible_sections, fn sections ->
      Enum.map(sections, fn entry ->
        if SectionHelpers.section_id(entry) == sid do
          update_entry_status(entry, status)
        else
          entry
        end
      end)
    end)
  end

  @doc """
  Mark a section as failed with error.
  """
  def fail_section(socket, section_id, error) do
    complete_section(socket, section_id, %{success: false, error: error})
  end

  @doc """
  Append streaming content for a section.

  Only appends if the section is still in the running set.
  Truncates to max length to prevent memory issues.
  """
  def append_streaming(socket, section_id, text) do
    sid = to_string(section_id)

    if MapSet.member?(socket.assigns.running_sections, sid) do
      update(socket, :streaming_content, fn content ->
        current = Map.get(content, sid, "")
        new_content = current <> text
        Map.put(content, sid, truncate_streaming(new_content))
      end)
    else
      socket
    end
  end

  @doc """
  Clear streaming content for sections no longer running.

  Call this after bulk status updates to clean up stale content.
  """
  def cleanup_streaming(socket) do
    update(socket, :streaming_content, fn content ->
      content
      |> Enum.filter(fn {section_id, _} ->
        MapSet.member?(socket.assigns.running_sections, section_id)
      end)
      |> Map.new()
    end)
  end

  @doc """
  Reset all running state (e.g., on page reload).
  """
  def reset_running_state(socket) do
    socket
    |> assign(:running_sections, MapSet.new())
    |> assign(:streaming_content, %{})
  end

  @doc """
  Set view mode (normal or debug with run_id).

  When switching to debug mode, visible_sections is set from the run.
  When switching to normal mode, visible_sections mirrors sections.
  """
  def set_view_mode(socket, :normal) do
    socket
    |> assign(:view_mode, :normal)
    |> assign(:visible_sections, socket.assigns.sections)
  end

  def set_view_mode(socket, {:debug, run_id, run_sections}) do
    socket
    |> assign(:view_mode, {:debug, run_id})
    |> assign(:visible_sections, run_sections)
  end

  # Private helpers

  defp truncate_streaming(text) do
    if String.length(text) > @max_streaming_length do
      String.slice(text, -@max_streaming_length, @max_streaming_length)
    else
      text
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Handle different entry formats for status updates
  defp update_entry_status(%{status: _} = entry, new_status) do
    %{entry | status: new_status}
  end

  defp update_entry_status(entry, _new_status), do: entry
end
