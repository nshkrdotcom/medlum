defmodule MedlumWeb.Admin.VastAILive.Styles do
  @moduledoc """
  Styling and CSS class functions for VastAILive.
  Provides consistent styling for status indicators, badges, and log levels.
  """

  # =============================================================================
  # Status Styling
  # =============================================================================

  @doc """
  Returns CSS classes for status container based on availability status.
  Supports operational, enabled, and disabled states.
  """
  def status_classes(status) do
    cond do
      status.operational? ->
        "bg-green-50 text-green-800 border-green-200 dark:bg-green-900/30 dark:text-green-100 dark:border-green-800"

      status.enabled? ->
        "bg-amber-50 text-amber-800 border-amber-200 dark:bg-amber-900/30 dark:text-amber-100 dark:border-amber-800"

      true ->
        "bg-red-50 text-red-800 border-red-200 dark:bg-red-900/30 dark:text-red-100 dark:border-red-800"
    end
  end

  @doc """
  Returns CSS classes for status indicator dot.
  Provides color coding: green (operational), amber (enabled), red (disabled).
  """
  def status_dot_classes(status) do
    cond do
      status.operational? -> "bg-green-500"
      status.enabled? -> "bg-amber-500"
      true -> "bg-red-500"
    end
  end

  @doc """
  Returns a human-readable status label based on availability status.
  Provides detailed diagnostics for non-operational states.
  """
  def status_label(status) do
    cond do
      status.operational? ->
        "Vast.ai ready"

      status.enabled? and not status.instance_manager_alive? ->
        "Instance manager offline"

      status.enabled? and not status.provisioning_state_alive? ->
        "Provisioning offline"

      status.enabled? ->
        "Vast.ai configured"

      true ->
        "Vast.ai disabled"
    end
  end

  # =============================================================================
  # Badge Styling
  # =============================================================================

  @doc """
  Returns CSS classes for instance status badges.
  Provides color-coded badges for running, loading, exited, and unknown states.
  """
  def status_badge_class("running") do
    "inline-flex items-center rounded-full bg-green-100 px-2 py-1 text-xs font-semibold text-green-800"
  end

  def status_badge_class("loading") do
    "inline-flex items-center rounded-full bg-yellow-100 px-2 py-1 text-xs font-semibold text-yellow-800"
  end

  def status_badge_class("exited") do
    "inline-flex items-center rounded-full bg-red-100 px-2 py-1 text-xs font-semibold text-red-800"
  end

  def status_badge_class(_) do
    "inline-flex items-center rounded-full bg-gray-100 px-2 py-1 text-xs font-semibold text-gray-800"
  end

  # =============================================================================
  # Log Level Styling
  # =============================================================================

  @doc """
  Returns CSS color class for log level.
  Supports success (green), error (red), warning (yellow), and info (blue).
  """
  def log_level_class(:success), do: "text-green-400"
  def log_level_class(:error), do: "text-red-400"
  def log_level_class(:warning), do: "text-yellow-400"
  def log_level_class(_), do: "text-blue-400"

  @doc """
  Returns icon/emoji for log level.
  Provides visual indicators: ✓ (success), ✗ (error), ⚠ (warning), → (info).
  """
  def log_level_icon(:success), do: "✓"
  def log_level_icon(:error), do: "✗"
  def log_level_icon(:warning), do: "⚠"
  def log_level_icon(_), do: "→"
end
