# 08: Reports LiveView State Consolidation

## Problem

`ReportsLive` maintains multiple section-related assigns that can drift out of sync:

```elixir
socket.assigns.sections           # Source of truth for section entries
socket.assigns.visible_sections   # What's displayed (may differ in debug view)
socket.assigns.running_sections   # MapSet of currently running section IDs
socket.assigns.streaming_content  # Map of section_id -> streaming text
socket.assigns.debug_expanded_sections  # MapSet of expanded sections in debug view
```

We already patched `lock_sections/2` to update both `@sections` and `@visible_sections`, but this is a symptom of deeper state management issues.

## Current State Analysis

### State Flow

```
load_workspace()
    |
    +-- assigns :sections (from DB)
    +-- assigns :visible_sections (copy of sections)

lock_sections(section_ids)
    |
    +-- updates :sections
    +-- updates :visible_sections (after fix)
    +-- updates :running_sections

handle_info({:section_run_complete, ...})
    |
    +-- updates :sections
    +-- does NOT update :visible_sections

select_debug_run()
    |
    +-- updates :visible_sections (from run details)
    +-- :sections unchanged
```

### Where They Diverge

| Event | @sections | @visible_sections | @running_sections |
|-------|-----------|-------------------|-------------------|
| `load_workspace` | Set from DB | Copy of sections | Computed |
| `lock_sections` | Updated | Updated (fixed) | Updated |
| `run_complete` | Updated | **NOT updated** | Updated |
| `select_debug_run` | Unchanged | Set from run | Unchanged |
| `stream_chunk` | Unchanged | Unchanged | Read-only |

### Template Usage

```elixir
# Line 4233 - Uses @sections for count
<%= completed_section_count(@sections) %>/<%= length(@sections) %> sections

# Line 4604 - Uses @visible_sections for display
<%= for section_entry <- @visible_sections do %>

# Line 4643 - Uses @running_sections for button state
disabled={MapSet.member?(@running_sections, to_string(section_entry.section.id))}
```

## Problems

1. **@visible_sections not updated on run complete** - Status may show stale
2. **@sections and @visible_sections semantics unclear** - When should they differ?
3. **No single source of truth** - Multiple places to check section state
4. **String/ID coercion scattered** - `to_string(section_entry.section.id)` everywhere

## Proposed Solution

### Consolidate into Single Derived View

```elixir
# lib/medlum_web/live/reports_live.ex

defmodule MedlumWeb.ReportsLive do
  # Single source of truth
  # @sections - always the canonical section data from DB
  # @view_mode - :normal | {:debug, run_id}
  # @running_sections - MapSet of running section IDs (strings)

  # Derived at render time
  defp displayable_sections(assigns) do
    case assigns.view_mode do
      :normal ->
        assigns.sections
        |> Enum.map(&enrich_section_for_display(&1, assigns))

      {:debug, run_id} ->
        assigns.debug_runs[run_id]
        |> sections_from_run()
        |> Enum.map(&enrich_section_for_display(&1, assigns))
    end
  end

  defp enrich_section_for_display(section_entry, assigns) do
    section_id = to_string(section_entry.section.id)

    %{
      section_entry |
      is_running: MapSet.member?(assigns.running_sections, section_id),
      streaming_content: Map.get(assigns.streaming_content, section_id),
      display_status: compute_display_status(section_entry, assigns)
    }
  end

  defp compute_display_status(entry, assigns) do
    section_id = to_string(entry.section.id)

    cond do
      MapSet.member?(assigns.running_sections, section_id) ->
        if Map.has_key?(assigns.streaming_content, section_id), do: "streaming", else: "running"

      entry.status == "error" ->
        "error"

      entry.status == "completed" ->
        "completed"

      true ->
        entry.status || "pending"
    end
  end
end
```

### Remove @visible_sections

```elixir
# Before
assign(socket, :visible_sections, sections)

# After - Just use @sections, derive display in template/helper
assign(socket, :sections, sections)
assign(socket, :view_mode, :normal)
```

### Simplify Template

```elixir
# Before
<%= for section_entry <- @visible_sections do %>
  <div data-status={section_entry.status}>
    <%= if MapSet.member?(@running_sections, to_string(section_entry.section.id)) do %>

# After
<%= for section <- displayable_sections(assigns) do %>
  <div data-status={section.display_status}>
    <%= if section.is_running do %>
```

### Centralize ID Handling

```elixir
# lib/medlum_web/live/reports_live/section_helpers.ex

defmodule MedlumWeb.ReportsLive.SectionHelpers do
  @moduledoc """
  Helper functions for section state management.
  """

  @doc """
  Normalize section ID to string form used in assigns.
  """
  def section_id(%{section: %{id: id}}), do: to_string(id)
  def section_id(%{section_template_id: id}), do: to_string(id)
  def section_id(id) when is_binary(id), do: id
  def section_id(id) when is_integer(id), do: to_string(id)

  @doc """
  Check if a section is in a set (handles ID normalization).
  """
  def in_set?(section, set) do
    MapSet.member?(set, section_id(section))
  end

  @doc """
  Add section to a set (handles ID normalization).
  """
  def add_to_set(section, set) do
    MapSet.put(set, section_id(section))
  end

  @doc """
  Remove section from a set (handles ID normalization).
  """
  def remove_from_set(section, set) do
    MapSet.delete(set, section_id(section))
  end
end
```

### State Transition Functions

```elixir
# lib/medlum_web/live/reports_live/state.ex

defmodule MedlumWeb.ReportsLive.State do
  @moduledoc """
  State transition functions for ReportsLive.

  All section state changes go through here to ensure consistency.
  """

  alias MedlumWeb.ReportsLive.SectionHelpers

  @doc """
  Mark sections as running (about to start execution).
  """
  def start_sections(socket, section_ids) do
    id_set = MapSet.new(Enum.map(section_ids, &to_string/1))

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
  end

  @doc """
  Mark a section as complete with result.
  """
  def complete_section(socket, section_id, result) do
    sid = to_string(section_id)
    status = if result.success?, do: "completed", else: "error"

    socket
    |> update(:running_sections, &MapSet.delete(&1, sid))
    |> update(:streaming_content, &Map.delete(&1, sid))
    |> update(:sections, fn sections ->
      Enum.map(sections, fn entry ->
        if SectionHelpers.section_id(entry) == sid do
          %{entry |
            status: status,
            last_run: result.run,
            error: result.error
          }
        else
          entry
        end
      end)
    end)
  end

  @doc """
  Append streaming content for a section.
  """
  def append_streaming(socket, section_id, text) do
    sid = to_string(section_id)

    # Only append if section is still running
    if MapSet.member?(socket.assigns.running_sections, sid) do
      update(socket, :streaming_content, fn content ->
        current = Map.get(content, sid, "")
        Map.put(content, sid, truncate_streaming(current <> text))
      end)
    else
      socket
    end
  end

  defp truncate_streaming(text, max_length \\ 50_000) do
    if String.length(text) > max_length do
      String.slice(text, -max_length, max_length)
    else
      text
    end
  end
end
```

## Benefits

1. **Single source of truth** - `@sections` is canonical, display derived
2. **No state drift** - Derived values can't get stale
3. **Clearer semantics** - `@view_mode` explicitly controls display source
4. **Centralized ID handling** - No scattered `to_string()` calls
5. **Testable transitions** - State module can be unit tested

## Migration

### Phase 1: Add Helpers

1. Create `SectionHelpers` module
2. Create `State` module
3. Keep existing code working

### Phase 2: Migrate Event Handlers

1. Replace inline state updates with `State.*` functions
2. Remove `@visible_sections` usage
3. Add `@view_mode` assign

### Phase 3: Update Template

1. Use `displayable_sections(assigns)` helper
2. Access enriched fields directly
3. Remove inline MapSet checks

### Phase 4: Cleanup

1. Remove `@visible_sections`
2. Remove `visible_sections/2` helper
3. Update tests

## Files to Modify

- `lib/medlum_web/live/reports_live.ex` - Main LiveView
- `lib/medlum_web/live/reports_live/section_helpers.ex` - New
- `lib/medlum_web/live/reports_live/state.ex` - New

## Testing

1. Section status updates correctly on run start
2. Section status updates correctly on run complete
3. Debug view shows run-specific sections
4. Switching between normal/debug view works
5. Streaming content appears for running sections
6. Streaming content clears on completion
