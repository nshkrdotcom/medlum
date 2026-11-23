defmodule Medlum.Documents.ProgressTracker do
  @moduledoc """
  Tracks multi-stage progress for document ingestion.

  Stages:
  1. Upload & Prepare (5%)
  2. OCR Processing (25%)
  3. Layout Analysis (25%)
  4. Table Extraction (20%)
  5. Assembly (15%)
  6. Persist & Index (10%)
  """

  @stage_weights %{
    1 => 0.05,
    2 => 0.25,
    3 => 0.25,
    4 => 0.20,
    5 => 0.15,
    6 => 0.10
  }

  @stage_names %{
    1 => "Upload & Prepare",
    2 => "OCR Processing",
    3 => "Layout Analysis",
    4 => "Table Extraction",
    5 => "Assembly",
    6 => "Persist & Index"
  }

  @doc """
  Calculate overall progress from stage progress map.

  ## Example

      iex> stages = %{1 => 100, 2 => 100, 3 => 50, 4 => 0, 5 => 0, 6 => 0}
      iex> ProgressTracker.calculate_overall(stages)
      42
  """
  def calculate_overall(stage_progress_map) do
    Enum.reduce(@stage_weights, 0.0, fn {stage, weight}, acc ->
      stage_pct = Map.get(stage_progress_map, stage, 0) / 100
      acc + weight * stage_pct * 100
    end)
    |> trunc()
    |> min(100)
  end

  @doc """
  Check if we should emit a progress update.

  Emits when either:
  - integer percentage increased, or
  - at least `min_interval_ms` elapsed since last emission (time-based debounce).
  """
  def should_emit?(state, new_overall, pages_done, min_interval_ms \\ nil) do
    min_interval_ms = min_interval_ms || progress_min_interval_ms()
    progress_changed? = trunc(new_overall) > trunc(state.last_emitted_progress)
    pages_changed? = pages_done != (state.last_pages_emitted || 0)
    elapsed_ms = now_ms() - (state.last_emitted_at || 0)

    # Emit immediately on page movement or progress increase; otherwise respect time-based debounce.
    progress_changed? or pages_changed? or elapsed_ms >= min_interval_ms
  end

  @doc """
  Get the stage number from a Docling stage name.
  """
  def docling_stage_to_number("preprocess"), do: 2
  def docling_stage_to_number("ocr"), do: 2
  def docling_stage_to_number("layout"), do: 3
  def docling_stage_to_number("table"), do: 4
  def docling_stage_to_number("assemble"), do: 5
  def docling_stage_to_number(_), do: 2

  @doc """
  Get the stage number from event type.
  """
  def event_type_to_stage("page_processed"), do: 5
  def event_type_to_stage("docling_started"), do: 2
  def event_type_to_stage("docling_completed"), do: 5
  def event_type_to_stage(_), do: nil

  @doc """
  Get human-readable stage name.
  """
  def stage_name(num), do: Map.get(@stage_names, num, "Processing")

  @doc """
  Get all stage names.
  """
  def stage_names, do: @stage_names

  @doc """
  Get stage weights.
  """
  def stage_weights, do: @stage_weights

  @doc """
  Create initial progress state for a job.
  """
  def initial_state do
    %{
      stages: %{
        1 => %{progress: 100, status: "completed"},
        2 => %{progress: 0, status: "pending"},
        3 => %{progress: 0, status: "pending"},
        4 => %{progress: 0, status: "pending"},
        5 => %{progress: 0, status: "pending"},
        6 => %{progress: 0, status: "pending"}
      },
      last_emitted_progress: 5,
      last_emitted_at: now_ms(),
      last_pages_emitted: 0,
      last_pages_total: nil,
      current_stage: 2
    }
  end

  @doc """
  Update stage progress and determine current active stage.
  """
  def update_stage(state, stage_num, progress) do
    updated_stages =
      state.stages
      |> Map.update(stage_num, %{progress: progress, status: "in_progress"}, fn s ->
        new_progress = max(s.progress, progress)
        status = if new_progress >= 100, do: "completed", else: "in_progress"
        %{s | progress: new_progress, status: status}
      end)
      |> maybe_mark_earlier_stages_complete(stage_num)

    # Determine current stage (first non-completed stage)
    current_stage =
      Enum.find(1..6, 6, fn n ->
        stage = Map.get(updated_stages, n, %{status: "pending"})
        stage.status != "completed"
      end)

    %{state | stages: updated_stages, current_stage: current_stage}
  end

  @doc """
  Format stages map for payload/metadata.
  """
  def format_stages_for_payload(stages) do
    Enum.into(stages, %{}, fn {k, v} ->
      # Convert both outer keys (stage numbers) and inner keys (status, progress) to strings
      stringified_v =
        Enum.into(v, %{}, fn {inner_k, inner_v} ->
          {to_string(inner_k), inner_v}
        end)

      {to_string(k), stringified_v}
    end)
  end

  @doc """
  Build progress payload for recording.
  """
  def build_progress_payload(state, pages_done, pages_total) do
    stage_progress_map = Enum.into(state.stages, %{}, fn {k, v} -> {k, v.progress} end)
    overall = calculate_overall(stage_progress_map)

    %{
      overall: overall,
      stage: state.current_stage,
      stage_name: stage_name(state.current_stage),
      stage_progress: get_in(state.stages, [state.current_stage, :progress]) || 0,
      pages_done: pages_done,
      pages_total: pages_total,
      stages: format_stages_for_payload(state.stages)
    }
  end

  @doc """
  Generate progress message for current state.
  """
  def progress_message(state, pages_done, pages_total) do
    stage_name = stage_name(state.current_stage)

    if pages_total && pages_total > 0 do
      "#{stage_name}: #{pages_done}/#{pages_total} pages"
    else
      stage_name
    end
  end

  # Mark all stages before the current one as completed
  defp maybe_mark_earlier_stages_complete(stages, current_stage) do
    Enum.reduce(1..(current_stage - 1), stages, fn n, acc ->
      Map.update(acc, n, %{progress: 100, status: "completed"}, fn s ->
        %{s | progress: 100, status: "completed"}
      end)
    end)
  end

  defp progress_min_interval_ms do
    Application.get_env(:medlum, :docling, [])
    |> Keyword.get(:progress_min_interval_ms, 250)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
