defmodule Medlum.AI.CitationSanitizerTest do
  use ExUnit.Case, async: true

  alias Medlum.AI.CitationSanitizer

  describe "sanitize_citations/2" do
    setup do
      # Sample document map
      document_map = %{
        mock_id_to_doc: %{
          "doc-001" => %{
            "id" => "550e8400-e29b-41d4-a716-446655440000",
            "mock_id" => "doc-001",
            "label" => "doc-001",
            "summary" => "Patient EKG Report"
          },
          "doc-002" => %{
            "id" => "550e8400-e29b-41d4-a716-446655440001",
            "mock_id" => "doc-002",
            "label" => "doc-002",
            "summary" => "Lab Results"
          }
        },
        id_to_doc: %{
          "550e8400-e29b-41d4-a716-446655440000" => %{
            "id" => "550e8400-e29b-41d4-a716-446655440000",
            "mock_id" => "doc-001",
            "label" => "doc-001"
          },
          "550e8400-e29b-41d4-a716-446655440001" => %{
            "id" => "550e8400-e29b-41d4-a716-446655440001",
            "mock_id" => "doc-002",
            "label" => "doc-002"
          }
        },
        name_to_doc: %{
          "ekg_report.pdf" => %{
            "id" => "550e8400-e29b-41d4-a716-446655440000",
            "mock_id" => "doc-001",
            "label" => "doc-001"
          },
          "patient ekg report" => %{
            "id" => "550e8400-e29b-41d4-a716-446655440000",
            "mock_id" => "doc-001",
            "label" => "doc-001"
          },
          "lab_results.pdf" => %{
            "id" => "550e8400-e29b-41d4-a716-446655440001",
            "mock_id" => "doc-002",
            "label" => "doc-002"
          }
        }
      }

      {:ok, document_map: document_map}
    end

    test "returns empty list for nil citations", %{document_map: document_map} do
      assert {:ok, [], []} = CitationSanitizer.sanitize_citations(nil, document_map)
    end

    test "returns empty list for empty citations", %{document_map: document_map} do
      assert {:ok, [], []} = CitationSanitizer.sanitize_citations([], document_map)
    end

    test "passes through valid citations unchanged", %{document_map: document_map} do
      citations = [
        %{
          "label" => "doc-001",
          "document_id" => "550e8400-e29b-41d4-a716-446655440000",
          "document_reference" => "doc-001",
          "line_start" => 10,
          "line_end" => 15,
          "excerpt" => "Normal sinus rhythm"
        }
      ]

      assert {:ok, cleaned, []} = CitationSanitizer.sanitize_citations(citations, document_map)
      assert length(cleaned) == 1
      assert hd(cleaned)["label"] == "doc-001"
    end

    test "repairs label with line suffix", %{document_map: document_map} do
      citations = [
        %{
          "label" => "doc-001:L101",
          "document_id" => "550e8400-e29b-41d4-a716-446655440000",
          "document_reference" => "doc-001",
          "line_start" => 101,
          "line_end" => 101,
          "excerpt" => "Test"
        }
      ]

      assert {:ok, [cleaned], logs} =
               CitationSanitizer.sanitize_citations(citations, document_map)

      assert cleaned["label"] == "doc-001"
      assert Enum.any?(logs, &(&1.field == :label))
    end

    test "repairs missing document_id from document_reference", %{document_map: document_map} do
      citations = [
        %{
          "label" => "doc-001",
          "document_reference" => "doc-001",
          "line_start" => 1,
          "line_end" => 1
        }
      ]

      assert {:ok, [cleaned], logs} =
               CitationSanitizer.sanitize_citations(citations, document_map)

      assert cleaned["document_id"] == "550e8400-e29b-41d4-a716-446655440000"
      assert Enum.any?(logs, &(&1.field == :document_id))
    end

    test "repairs filename reference to mock_id", %{document_map: document_map} do
      citations = [
        %{
          "label" => "ekg_report.pdf",
          "document_reference" => "ekg_report.pdf",
          "line_start" => 1,
          "line_end" => 1
        }
      ]

      assert {:ok, [cleaned], logs} =
               CitationSanitizer.sanitize_citations(citations, document_map)

      assert cleaned["label"] == "doc-001"
      assert cleaned["document_reference"] == "doc-001"
      assert cleaned["document_id"] == "550e8400-e29b-41d4-a716-446655440000"
      assert length(logs) > 0
    end

    test "repairs missing line numbers with defaults", %{document_map: document_map} do
      citations = [
        %{
          "label" => "doc-001",
          "document_id" => "550e8400-e29b-41d4-a716-446655440000",
          "document_reference" => "doc-001"
        }
      ]

      assert {:ok, [cleaned], logs} =
               CitationSanitizer.sanitize_citations(citations, document_map)

      assert cleaned["line_start"] == 1
      assert cleaned["line_end"] == 1
      assert Enum.any?(logs, &(&1.field == :line_numbers))
    end

    test "repairs missing excerpt", %{document_map: document_map} do
      citations = [
        %{
          "label" => "doc-001",
          "document_id" => "550e8400-e29b-41d4-a716-446655440000",
          "document_reference" => "doc-001",
          "line_start" => 1,
          "line_end" => 1
        }
      ]

      assert {:ok, [cleaned], logs} =
               CitationSanitizer.sanitize_citations(citations, document_map)

      assert cleaned["excerpt"] == ""
      assert Enum.any?(logs, &(&1.field == :excerpt))
    end

    test "swaps line_start and line_end if in wrong order", %{document_map: document_map} do
      citations = [
        %{
          "label" => "doc-001",
          "document_id" => "550e8400-e29b-41d4-a716-446655440000",
          "document_reference" => "doc-001",
          "line_start" => 15,
          "line_end" => 10,
          "excerpt" => ""
        }
      ]

      assert {:ok, [cleaned], logs} =
               CitationSanitizer.sanitize_citations(citations, document_map)

      assert cleaned["line_start"] == 10
      assert cleaned["line_end"] == 15
      assert Enum.any?(logs, &(&1.field == :line_numbers and &1.reason =~ "Swapped"))
    end

    test "returns error for completely invalid citation", %{document_map: document_map} do
      citations = [
        %{
          "label" => "invalid",
          "document_reference" => "nonexistent",
          "line_start" => "not a number",
          "line_end" => -5
        }
      ]

      assert {:error, errors} = CitationSanitizer.sanitize_citations(citations, document_map)
      assert length(errors) == 1
      {_citation, error_messages} = hd(errors)
      assert is_list(error_messages)
      assert length(error_messages) > 0
    end

    test "handles mixed valid and repairable citations", %{document_map: document_map} do
      citations = [
        %{
          "label" => "doc-001",
          "document_id" => "550e8400-e29b-41d4-a716-446655440000",
          "document_reference" => "doc-001",
          "line_start" => 1,
          "line_end" => 1,
          "excerpt" => "Valid citation"
        },
        %{
          "label" => "doc-002:L50",
          "document_reference" => "doc-002",
          "line_start" => 50,
          "line_end" => 50
        }
      ]

      assert {:ok, cleaned, logs} = CitationSanitizer.sanitize_citations(citations, document_map)
      assert length(cleaned) == 2
      assert hd(cleaned)["label"] == "doc-001"
      assert Enum.at(cleaned, 1)["label"] == "doc-002"
      assert Enum.at(cleaned, 1)["document_id"] == "550e8400-e29b-41d4-a716-446655440001"
      assert length(logs) > 0
    end
  end

  describe "validate_citation/1" do
    test "validates correct citation" do
      citation = %{
        "label" => "doc-001",
        "document_id" => "550e8400-e29b-41d4-a716-446655440000",
        "document_reference" => "doc-001",
        "line_start" => 10,
        "line_end" => 15,
        "excerpt" => "Some text"
      }

      assert :ok = CitationSanitizer.validate_citation(citation)
    end

    test "fails on invalid label format" do
      citation = %{
        "label" => "document-1",
        "document_id" => "550e8400-e29b-41d4-a716-446655440000",
        "document_reference" => "doc-001",
        "line_start" => 1,
        "line_end" => 1
      }

      assert {:error, errors} = CitationSanitizer.validate_citation(citation)
      assert Enum.any?(errors, &String.contains?(&1, "label must be in format"))
    end

    test "fails on invalid UUID" do
      citation = %{
        "label" => "doc-001",
        "document_id" => "not-a-uuid",
        "document_reference" => "doc-001",
        "line_start" => 1,
        "line_end" => 1
      }

      assert {:error, errors} = CitationSanitizer.validate_citation(citation)
      assert Enum.any?(errors, &String.contains?(&1, "document_id must be a valid UUID"))
    end

    test "fails on missing required fields" do
      citation = %{
        "label" => "doc-001"
      }

      assert {:error, errors} = CitationSanitizer.validate_citation(citation)
      assert length(errors) > 0
    end

    test "fails on negative line numbers" do
      citation = %{
        "label" => "doc-001",
        "document_id" => "550e8400-e29b-41d4-a716-446655440000",
        "document_reference" => "doc-001",
        "line_start" => -1,
        "line_end" => 5
      }

      assert {:error, errors} = CitationSanitizer.validate_citation(citation)
      assert Enum.any?(errors, &String.contains?(&1, "line_start"))
    end

    test "fails when line_end < line_start" do
      citation = %{
        "label" => "doc-001",
        "document_id" => "550e8400-e29b-41d4-a716-446655440000",
        "document_reference" => "doc-001",
        "line_start" => 10,
        "line_end" => 5
      }

      assert {:error, errors} = CitationSanitizer.validate_citation(citation)
      assert Enum.any?(errors, &String.contains?(&1, "line_end must be >= line_start"))
    end
  end

  describe "repair_citation/2" do
    setup do
      document_map = %{
        mock_id_to_doc: %{
          "doc-001" => %{
            "id" => "550e8400-e29b-41d4-a716-446655440000",
            "mock_id" => "doc-001"
          }
        },
        id_to_doc: %{
          "550e8400-e29b-41d4-a716-446655440000" => %{
            "id" => "550e8400-e29b-41d4-a716-446655440000",
            "mock_id" => "doc-001"
          }
        },
        name_to_doc: %{}
      }

      {:ok, document_map: document_map}
    end

    test "strips line suffix from label", %{document_map: document_map} do
      citation = %{"label" => "doc-001:L50"}

      {repaired, logs} = CitationSanitizer.repair_citation(citation, document_map)

      assert repaired["label"] == "doc-001"
      assert Enum.any?(logs, &(&1.field == :label))
    end

    test "infers missing document_id from document_reference", %{document_map: document_map} do
      citation = %{
        "label" => "doc-001",
        "document_reference" => "doc-001"
      }

      {repaired, logs} = CitationSanitizer.repair_citation(citation, document_map)

      assert repaired["document_id"] == "550e8400-e29b-41d4-a716-446655440000"
      assert Enum.any?(logs, &(&1.field == :document_id))
    end

    test "defaults missing line numbers to 1", %{document_map: document_map} do
      citation = %{
        "label" => "doc-001",
        "document_id" => "550e8400-e29b-41d4-a716-446655440000",
        "document_reference" => "doc-001"
      }

      {repaired, logs} = CitationSanitizer.repair_citation(citation, document_map)

      assert repaired["line_start"] == 1
      assert repaired["line_end"] == 1
      assert Enum.any?(logs, &(&1.field == :line_numbers))
    end

    test "extracts line number from label suffix", %{document_map: document_map} do
      citation = %{
        "label" => "doc-001:L101",
        "document_id" => "550e8400-e29b-41d4-a716-446655440000",
        "document_reference" => "doc-001"
      }

      {repaired, logs} = CitationSanitizer.repair_citation(citation, document_map)

      assert repaired["label"] == "doc-001"
      assert repaired["line_start"] == 101
      assert repaired["line_end"] == 101
      assert length(logs) > 0
    end

    test "ensures excerpt field exists", %{document_map: document_map} do
      citation = %{
        "label" => "doc-001",
        "document_id" => "550e8400-e29b-41d4-a716-446655440000",
        "document_reference" => "doc-001",
        "line_start" => 1,
        "line_end" => 1
      }

      {repaired, logs} = CitationSanitizer.repair_citation(citation, document_map)

      assert repaired["excerpt"] == ""
      assert Enum.any?(logs, &(&1.field == :excerpt))
    end
  end

  describe "log_repairs/2" do
    test "logs repair information" do
      repair_logs = [
        %{
          field: :label,
          old_value: "doc-001:L50",
          new_value: "doc-001",
          reason: "Stripped suffix"
        },
        %{field: :document_id, old_value: nil, new_value: "uuid-123", reason: "Looked up"}
      ]

      # Should not crash
      assert :ok = CitationSanitizer.log_repairs(repair_logs, %{section_run_id: "test-123"})
    end

    test "handles empty repair logs" do
      assert :ok = CitationSanitizer.log_repairs([], %{})
    end
  end
end
