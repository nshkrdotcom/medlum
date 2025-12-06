defmodule Lumainus.Repo.Migrations.FixCitationLabelConsistency do
  @moduledoc """
  Fix citation label inconsistencies across the system.

  This migration addresses citation labels that use incorrect formats:
  - Some use "doc-1" instead of "doc-001" (missing zero-padding)
  - Some use UUIDs instead of mock_ids
  - Some use filenames instead of mock_ids
  - Some inline citations are missing document_id

  The goal is to standardize all citation labels to the format "doc-XXX"
  where XXX is a zero-padded 3-digit number.

  Changes:
  1. Update report_section_citations.citation_label to use "doc-XXX" format
  2. Update inline_citations JSON in report_section_runs to use consistent labels
  3. Generate labels based on document sequence or hash if not available
  """
  use Ecto.Migration

  def up do
    # Fix citation labels in report_section_citations table
    execute(&fix_citation_labels/0)

    # Fix inline citations in report_section_runs table
    execute(&fix_inline_citations/0)
  end

  def down do
    # No-op: We cannot reliably reverse this migration
    # The old inconsistent labels are lost
    :ok
  end

  defp fix_citation_labels do
    repo = Lumainus.Repo

    # Get all citations with their associated documents
    {:ok, result} =
      repo.query(
        """
        SELECT
          c.id,
          c.citation_label,
          c.document_id,
          d.metadata
        FROM report_section_citations c
        INNER JOIN document_uploads d ON c.document_id = d.id
        WHERE c.citation_label IS NOT NULL
        """,
        []
      )

    for [citation_id, old_label, document_id, metadata] <- result.rows do
      new_label = generate_label(old_label, document_id, metadata)

      if new_label != old_label do
        repo.query!(
          "UPDATE report_section_citations SET citation_label = $1 WHERE id = $2",
          [new_label, citation_id]
        )
      end
    end

    :ok
  end

  defp fix_inline_citations do
    repo = Lumainus.Repo

    # Get all section runs with inline citations
    {:ok, result} =
      repo.query(
        """
        SELECT
          id,
          inline_citations
        FROM report_section_runs
        WHERE inline_citations IS NOT NULL
          AND inline_citations != '{}'::jsonb
        """,
        []
      )

    for [section_run_id, inline_citations] <- result.rows do
      if is_map(inline_citations) and Map.has_key?(inline_citations, "entries") do
        entries = Map.get(inline_citations, "entries", [])

        if is_list(entries) and length(entries) > 0 do
          fixed_entries = fix_citation_entries(entries, repo)
          fixed_citations = Map.put(inline_citations, "entries", fixed_entries)

          repo.query!(
            "UPDATE report_section_runs SET inline_citations = $1 WHERE id = $2",
            [fixed_citations, section_run_id]
          )
        end
      end
    end

    :ok
  end

  defp fix_citation_entries(entries, repo) do
    Enum.map(entries, fn entry ->
      if is_map(entry) do
        doc_id = Map.get(entry, "document_id")
        old_label = Map.get(entry, "label")
        old_ref = Map.get(entry, "document_reference")

        # Get document metadata to generate proper label
        metadata = get_document_metadata(repo, doc_id)
        new_label = generate_label(old_label || old_ref, doc_id, metadata)

        entry
        |> Map.put("label", new_label)
        |> Map.put("document_reference", new_label)
      else
        entry
      end
    end)
  end

  defp get_document_metadata(_repo, nil), do: %{}

  defp get_document_metadata(repo, document_id) when is_binary(document_id) do
    # Convert string UUID to binary format for Postgrex
    case Ecto.UUID.dump(document_id) do
      {:ok, binary_uuid} ->
        case repo.query("SELECT metadata FROM document_uploads WHERE id = $1", [binary_uuid]) do
          {:ok, %{rows: [[metadata]]}} when is_map(metadata) -> metadata
          _ -> %{}
        end

      :error ->
        %{}
    end
  end

  defp get_document_metadata(_repo, _), do: %{}

  defp generate_label(nil, document_id, _metadata) do
    # No label available, generate from document ID hash
    hash = :erlang.phash2(document_id, 999) + 1
    format_label(hash)
  end

  defp generate_label(label, document_id, metadata) when is_binary(label) do
    cond do
      # Already in correct format "doc-XXX"
      Regex.match?(~r/^doc-\d{3}$/, label) ->
        label

      # Has correct prefix but wrong padding "doc-1" -> "doc-001"
      match = Regex.run(~r/^doc-(\d+)$/, label) ->
        [_, num] = match
        {int, _} = Integer.parse(num)
        format_label(int)

      # Check if metadata has a properly formatted mock_id
      is_map(metadata) and is_binary(metadata["mock_id"]) and
          Regex.match?(~r/^doc-\d{3}$/, metadata["mock_id"]) ->
        metadata["mock_id"]

      # Check if metadata has sequence number
      is_map(metadata) and not is_nil(metadata["sequence"]) ->
        case Integer.parse(to_string(metadata["sequence"])) do
          {int, _} -> format_label(int)
          :error -> generate_from_hash(document_id)
        end

      # Default: generate from document ID hash
      true ->
        generate_from_hash(document_id)
    end
  end

  defp generate_label(_label, document_id, _metadata) do
    generate_from_hash(document_id)
  end

  defp generate_from_hash(document_id) do
    hash = :erlang.phash2(document_id, 999) + 1
    format_label(hash)
  end

  defp format_label(number) when is_integer(number) do
    # Ensure number is in range 1-999
    clamped = max(1, min(999, number))
    "doc-#{String.pad_leading(Integer.to_string(clamped), 3, "0")}"
  end

  defp format_label(_), do: "doc-001"
end
