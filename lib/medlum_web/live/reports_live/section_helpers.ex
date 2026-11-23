defmodule MedlumWeb.ReportsLive.SectionHelpers do
  @moduledoc """
  Helper functions for section state management in ReportsLive.

  Centralizes ID handling and set operations to avoid scattered
  `to_string()` calls and inconsistent ID comparisons.
  """

  @doc """
  Normalize section ID to string form used in assigns.

  Handles various entry formats:
  - `%{section: %{id: id}}` - Normal section entry
  - `%{section_template_id: id}` - Section run entry
  - Binary or integer ID directly
  """
  @spec section_id(map() | binary() | integer()) :: String.t()
  def section_id(%{section: %{id: id}}), do: to_string(id)
  def section_id(%{section_template_id: id}), do: to_string(id)
  def section_id(id) when is_binary(id), do: id
  def section_id(id) when is_integer(id), do: to_string(id)

  @doc """
  Check if a section is in a set (handles ID normalization).
  """
  @spec in_set?(map() | binary() | integer(), MapSet.t()) :: boolean()
  def in_set?(section, set) do
    MapSet.member?(set, section_id(section))
  end

  @doc """
  Add section to a set (handles ID normalization).
  """
  @spec add_to_set(map() | binary() | integer(), MapSet.t()) :: MapSet.t()
  def add_to_set(section, set) do
    MapSet.put(set, section_id(section))
  end

  @doc """
  Remove section from a set (handles ID normalization).
  """
  @spec remove_from_set(map() | binary() | integer(), MapSet.t()) :: MapSet.t()
  def remove_from_set(section, set) do
    MapSet.delete(set, section_id(section))
  end

  @doc """
  Convert a list of IDs to a MapSet of string IDs.
  """
  @spec ids_to_set(list()) :: MapSet.t()
  def ids_to_set(ids) when is_list(ids) do
    ids
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  @doc """
  Get status for display, considering running state.

  Priority:
  1. If running with streaming content -> "streaming"
  2. If running without streaming content -> "running"
  3. Otherwise -> entry.status
  """
  @spec display_status(map(), MapSet.t(), map()) :: String.t()
  def display_status(entry, running_sections, streaming_content) do
    sid = section_id(entry)

    cond do
      MapSet.member?(running_sections, sid) ->
        if Map.has_key?(streaming_content, sid), do: "streaming", else: "running"

      true ->
        entry.status || "pending"
    end
  end

  @doc """
  Check if a section is currently running.
  """
  @spec running?(map(), MapSet.t()) :: boolean()
  def running?(entry, running_sections) do
    in_set?(entry, running_sections)
  end

  @doc """
  Get streaming content for a section, if any.
  """
  @spec get_streaming_content(map(), map()) :: String.t() | nil
  def get_streaming_content(entry, streaming_content) do
    Map.get(streaming_content, section_id(entry))
  end
end
