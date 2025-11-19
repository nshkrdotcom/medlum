defmodule Lumainus.LLM.MockClient do
  @moduledoc """
  Deterministic adapter used in tests to avoid network calls while exercising the
  SectionRunner pipeline end-to-end.
  """

  @behaviour Lumainus.LLM.Client

  @impl true
  def generate_object(_model_spec, messages, _schema, opts \\ []) do
    context = Keyword.get(opts, :prompt_context) || %{}
    documents = Map.get(context, :documents) || Map.get(context, "documents") || []
    first_doc = List.first(documents) || %{}
    doc_label = first_doc["label"] || first_doc[:label] || "Doc"
    doc_id = first_doc["id"] || first_doc[:id] || "doc-001"

    prompt_excerpt =
      messages
      |> Enum.filter(fn message ->
        role = Map.get(message, :role) || Map.get(message, "role")
        role in [:user, "user"]
      end)
      |> Enum.map(&(Map.get(&1, :content) || Map.get(&1, "content")))
      |> Enum.reject(&is_nil/1)
      |> List.last()
      |> to_string()
      |> String.slice(0, 140)

    markdown = """
    ### Mock Section Output

    #{prompt_excerpt}

    Evidence: [#{doc_label}:L001]
    """

    object = %{
      "title" => "Mocked Draft",
      "summary" => "Deterministic summary for testing.",
      "markdown" => markdown,
      "citations" => [
        %{
          "label" => doc_label,
          "document_id" => doc_id,
          "document_reference" => doc_label,
          "line_start" => 1,
          "line_end" => 1
        }
      ]
    }

    {:ok,
     %{
       "object" => object,
       "text" => markdown,
       "usage" => %{"total_tokens" => 64}
     }}
  end
end
