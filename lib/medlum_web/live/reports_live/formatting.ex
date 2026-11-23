defmodule MedlumWeb.ReportsLive.Formatting do
  @moduledoc """
  Formatting helper functions for ReportsLive.

  This module contains various formatting utilities for displaying
  data in the reports interface, including:
  - Byte size formatting
  - Timestamp formatting
  - Timeout formatting
  - Token count formatting
  - Line range formatting
  - Text truncation
  - Error message humanization
  """

  alias Ecto.Changeset
  alias MedlumWeb.ReportsLive.CitationHelpers
  import MedlumWeb.DateTimeHelpers

  # Byte size formatting

  def format_byte_size(nil), do: "—"

  def format_byte_size(bytes) when is_integer(bytes) do
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

  # Timestamp formatting

  def format_timestamp(nil, _locale, _timezone), do: "recently"

  def format_timestamp(dt, locale, timezone) do
    format_datetime(dt, locale: locale, timezone: timezone, format: :medium) ||
      Calendar.strftime(dt, "%b %d · %H:%M UTC")
  end

  def format_health_timestamp(nil, _locale, _timezone), do: "no recent checks"

  def format_health_timestamp(%{responded_at: %DateTime{} = dt}, locale, timezone) do
    format_timestamp(dt, locale, timezone)
  end

  def format_health_timestamp(%{inserted_at: %DateTime{} = dt}, locale, timezone) do
    format_timestamp(dt, locale, timezone)
  end

  def format_health_timestamp(_, _locale, _timezone), do: "no recent checks"

  # Timeout formatting

  def format_timeout_remaining(nil), do: "expired"

  def format_timeout_remaining(%DateTime{} = dt) do
    diff = DateTime.diff(dt, DateTime.utc_now(), :second)
    format_timeout_diff(diff)
  end

  def format_timeout_remaining(iso_string) when is_binary(iso_string) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(iso_string) do
      diff = DateTime.diff(datetime, DateTime.utc_now(), :second)
      format_timeout_diff(diff)
    else
      _ -> "—"
    end
  end

  def format_timeout_remaining(_), do: "—"

  def format_timeout_diff(diff) do
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

  # Token count formatting

  def format_token_count(nil), do: "—"

  def format_token_count(count) when is_integer(count) and count >= 1000 do
    "#{Float.round(count / 1000, 1)}k"
  end

  def format_token_count(count) when is_integer(count), do: Integer.to_string(count)
  def format_token_count(_), do: "—"

  # Line range formatting

  def format_line_range(nil, nil), do: "—"

  def format_line_range(start_line, nil) when is_integer(start_line) do
    "L#{pad_line(start_line)}"
  end

  def format_line_range(nil, end_line) when is_integer(end_line) do
    "L#{pad_line(end_line)}"
  end

  def format_line_range(start_line, end_line) when start_line == end_line do
    "L#{pad_line(start_line)}"
  end

  def format_line_range(start_line, end_line) do
    "L#{pad_line(start_line)}-L#{pad_line(end_line)}"
  end

  def pad_line(line) when is_integer(line) do
    line
    |> Integer.to_string()
    |> String.pad_leading(3, "0")
  end

  def pad_line(_), do: "000"

  # Run formatting (delegates to CitationHelpers for citation processing)

  def format_run(nil), do: nil

  def format_run(run) do
    citations = Enum.map(run.citations || [], &CitationHelpers.format_citation/1)
    inline = CitationHelpers.format_inline_citations(run.inline_citations, citations)

    %{
      id: run.id,
      status: run.status,
      output_markdown: run.output_markdown,
      updated_at: run.updated_at,
      citations: citations,
      inline_citations: inline,
      doc_citations: CitationHelpers.aggregate_doc_citations(inline, citations)
    }
  end

  # Text truncation

  def truncate_with_flag(nil, _limit), do: {nil, false}

  def truncate_with_flag(value, limit) when is_integer(limit) and limit > 0 do
    text = to_string(value)
    truncated = String.slice(text, 0, limit)
    {truncated, byte_size(text) > byte_size(truncated)}
  end

  def truncate_with_flag(value, _limit), do: {value, false}

  def truncate(text, limit) do
    if String.length(text) <= limit do
      text
    else
      String.slice(text, 0, limit) <> "…"
    end
  end

  # Integer parsing

  def parse_int(nil), do: nil
  def parse_int(""), do: nil
  def parse_int(value) when is_integer(value), do: value

  def parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      _ -> nil
    end
  end

  def parse_int(_), do: nil

  def strip_leading_zeros(rest) do
    case Integer.parse(rest) do
      {num, _} -> Integer.to_string(num)
      _ -> rest
    end
  end

  # Error humanization

  def humanize_errors(%Changeset{} = changeset) do
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

  def humanize_field(field) when is_atom(field) do
    field
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
