defmodule Lumainus.AI.MockClient do
  @moduledoc """
  Deterministic LLM client used in tests to avoid network calls.
  """

  @behaviour Lumainus.AI.Client

  @impl true
  def generate_object(_model_spec, _context, _schema, _opts \\ []) do
    section_title = "Mock Section"
    reference = "doc-001"
    line_number = 1

    markdown = """
    ## #{section_title}

    Key findings referenced from #{reference} line #{line_number}.

    [#{reference}:L#{String.pad_leading(Integer.to_string(line_number), 3, "0")}]
    """

    object = %{
      "title" => "#{section_title} Summary",
      "summary" => "Automated summary for #{section_title}.",
      "markdown" => markdown,
      "citations" => [
        %{
          "label" => reference,
          "document_reference" => reference,
          "line_start" => line_number,
          "line_end" => line_number
        }
      ]
    }

    {:ok, %{"object" => object, "text" => markdown, "usage" => %{"total_tokens" => 128}}}
  end
end
