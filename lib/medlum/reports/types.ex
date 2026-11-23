defmodule Medlum.Reports.Types do
  @moduledoc """
  Type definitions and validation for Reports module.
  """

  require Logger

  @type execution_mode :: :streaming | :batch

  @type run_sections_opts :: [
          mode: execution_mode(),
          priority: :normal | :high,
          timeout_ms: pos_integer()
        ]

  @doc """
  Validate and normalize run_sections options.

  ## Examples

      iex> Types.validate_run_options([mode: :streaming])
      {:ok, [mode: :streaming, priority: :normal, timeout_ms: 120_000]}

      iex> Types.validate_run_options([stream: true])
      {:ok, [mode: :streaming, priority: :normal, timeout_ms: 120_000]}

      iex> Types.validate_run_options([mode: :invalid])
      {:error, {:invalid_mode, :invalid, "must be :streaming or :batch"}}
  """
  @spec validate_run_options(keyword()) :: {:ok, run_sections_opts()} | {:error, term()}
  def validate_run_options(opts) do
    with {:ok, mode} <- validate_mode(opts),
         {:ok, priority} <- validate_priority(opts),
         {:ok, timeout} <- validate_timeout(opts) do
      {:ok, [mode: mode, priority: priority, timeout_ms: timeout]}
    end
  end

  @doc """
  Validate options, raising on error.
  """
  @spec validate_run_options!(keyword()) :: run_sections_opts()
  def validate_run_options!(opts) do
    case validate_run_options(opts) do
      {:ok, validated} -> validated
      {:error, error} -> raise ArgumentError, format_error(error)
    end
  end

  defp validate_mode(opts) do
    mode_opt = Keyword.get(opts, :mode)
    stream_opt = Keyword.get(opts, :stream)

    case {mode_opt, stream_opt} do
      {nil, true} ->
        Logger.warning("Deprecated: `stream: true` option. Use `mode: :streaming` instead.")

        {:ok, :streaming}

      {nil, false} ->
        {:ok, :batch}

      {nil, nil} ->
        {:ok, :batch}

      {:streaming, nil} ->
        {:ok, :streaming}

      {:batch, nil} ->
        {:ok, :batch}

      {_mode, stream} when not is_nil(stream) ->
        {:error, {:conflicting_options, :mode, :stream, "cannot specify both :mode and :stream"}}

      {other, _} ->
        {:error, {:invalid_mode, other, "must be :streaming or :batch"}}
    end
  end

  defp validate_priority(opts) do
    case Keyword.get(opts, :priority, :normal) do
      :normal -> {:ok, :normal}
      :high -> {:ok, :high}
      other -> {:error, {:invalid_priority, other, "must be :normal or :high"}}
    end
  end

  defp validate_timeout(opts) do
    case Keyword.get(opts, :timeout_ms, 120_000) do
      timeout when is_integer(timeout) and timeout > 0 -> {:ok, timeout}
      other -> {:error, {:invalid_timeout, other, "must be a positive integer"}}
    end
  end

  defp format_error({:invalid_mode, value, message}) do
    "Invalid mode #{inspect(value)}: #{message}"
  end

  defp format_error({:invalid_priority, value, message}) do
    "Invalid priority #{inspect(value)}: #{message}"
  end

  defp format_error({:invalid_timeout, value, message}) do
    "Invalid timeout #{inspect(value)}: #{message}"
  end

  defp format_error({:conflicting_options, opt1, opt2, message}) do
    "Conflicting options #{opt1} and #{opt2}: #{message}"
  end
end
