defmodule Lumainus.AI.SectionRunner do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Lumainus.AI
  alias Lumainus.AI.LlmInvocation
  alias Lumainus.Documents.DocumentUpload
  alias Lumainus.Repo

  alias Lumainus.Reports.{
    ReportRun,
    ReportSectionCitation,
    ReportSectionRun,
    ReportSectionTemplate
  }

  alias ReqLLM.Context
  require EEx
  require Logger

  @system_prompt """
  You are Lumainus, a clinical documentation system. Produce structured markdown with inline citations like [doc-001].
  """

  def run_section(
        scope,
        %ReportRun{} = report_run,
        %ReportSectionTemplate{} = section_template,
        patient,
        documents,
        _opts \\ []
      ) do
    prompt_context = build_prompt_context(section_template, patient, documents)

    prompt_text =
      render_prompt(section_template.prompt_template, prompt_context, section_template.title)

    schema = decode_schema(section_template.output_schema)
    model_spec = AI.model_spec(section_template)
    options = AI.options(section_template)

    llm =
      %LlmInvocation{}
      |> LlmInvocation.changeset(%{
        tenant_id: scope.tenant_id,
        provider: section_template.provider,
        model: section_template.model,
        prompt_text: prompt_text,
        prompt_context: prompt_context,
        status: "pending",
        temperature: section_template.temperature,
        max_output_tokens: section_template.max_output_tokens
      })
      |> Repo.insert!()

    section_run =
      %ReportSectionRun{}
      |> ReportSectionRun.changeset(%{
        report_run_id: report_run.id,
        section_template_id: section_template.id,
        status: "running",
        prompt_inputs: prompt_context,
        llm_invocation_id: llm.id
      })
      |> Repo.insert!()

    started = System.monotonic_time()

    case invoke_llm(model_spec, prompt_text, schema, options) do
      {:ok, response} ->
        duration = duration_ms(started)
        normalized = normalize_response(response)
        persist_success(section_run, llm, normalized, prompt_context, documents, duration)

      {:error, reason} ->
        duration = duration_ms(started)
        fallback = fallback_payload(section_template, prompt_context)
        persist_failure(section_run, llm, reason, fallback, prompt_context, documents, duration)
    end
  end

  defp build_prompt_context(section_template, patient, documents) do
    profile = Map.get(patient, :current_profile) || %{}

    doc_payloads =
      Enum.map(documents, fn doc ->
        parse = List.first(doc.parses || [])
        metadata = doc.metadata || %{}
        clean_text = (parse && parse.parsed_text) || metadata["summary"] || "Pending ingestion"

        %{
          "id" => doc.id,
          "mock_id" => metadata["mock_id"],
          "label" => doc_label(doc),
          "summary" => metadata["summary"] || "Pending ingestion",
          "kind" => doc.document_kind,
          "provider" => metadata["provider"],
          "content" => clean_text
        }
      end)

    %{
      section_title: section_template.title,
      patient: %{
        full_name: build_name(profile),
        mrn: profile.mrn || "unknown",
        date_of_birth: profile.date_of_birth && Date.to_iso8601(profile.date_of_birth),
        sex: profile.sex
      },
      documents: doc_payloads,
      documents_summary: documents_summary(doc_payloads),
      documents_text: documents_text(doc_payloads)
    }
  end

  defp render_prompt(template, context, section_title) do
    patient = symbolize_keys(context[:patient] || %{})

    assigns = [
      section_title: section_title,
      patient: patient,
      documents: context[:documents],
      documents_summary: context[:documents_summary],
      documents_text: context[:documents_text]
    ]

    EEx.eval_string(template, assigns)
  end

  defp invoke_llm(model_spec, prompt_text, schema, options) do
    messages =
      Context.new([
        Context.system(@system_prompt),
        Context.user(prompt_text)
      ])

    AI.client().generate_object(model_spec, messages, schema, options)
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp persist_success(section_run, llm, normalized, prompt_context, documents, duration) do
    Repo.update!(
      Changeset.change(llm, %{
        response_text: normalized.text,
        response_object: normalized.object,
        usage: normalized.usage,
        status: "completed",
        req_duration_ms: duration
      })
    )

    Repo.update!(
      Changeset.change(section_run, %{
        status: "completed",
        output_markdown: normalized.markdown,
        output_object: normalized.object,
        confidence_score: normalized.confidence,
        inline_citations: normalized.citations,
        error: nil
      })
    )

    persist_citations(section_run, normalized.citations, documents, prompt_context)
  end

  defp persist_failure(section_run, llm, reason, fallback, prompt_context, documents, duration) do
    error_payload = %{message: inspect(reason)}

    Repo.update!(
      Changeset.change(llm, %{
        status: "error",
        error: error_payload,
        response_object: fallback,
        req_duration_ms: duration
      })
    )

    Repo.update!(
      Changeset.change(section_run, %{
        status: "error",
        output_markdown: fallback["markdown"],
        output_object: fallback,
        inline_citations: fallback["citations"],
        error: error_payload
      })
    )

    persist_citations(section_run, fallback["citations"], documents, prompt_context)
  end

  defp persist_citations(_section_run, nil, _documents, _context), do: :ok

  defp persist_citations(section_run, citations, documents, prompt_context) do
    docs_by_mock =
      documents
      |> Enum.map(fn doc -> {doc.metadata && doc.metadata["mock_id"], doc} end)
      |> Enum.into(%{})

    Enum.each(citations, fn citation ->
      mock_id = citation["document_reference"] || citation["label"]

      doc =
        docs_by_mock[mock_id] ||
          Enum.find(documents, fn d -> d.id == citation["document_id"] end)

      if doc do
        %ReportSectionCitation{}
        |> ReportSectionCitation.changeset(%{
          section_run_id: section_run.id,
          document_id: doc.id,
          citation_label: citation["label"] || mock_id || "doc",
          source_span: %{
            "mock_id" => mock_id,
            "summary" => doc.metadata && doc.metadata["summary"],
            "context" => prompt_context[:section_title]
          }
        })
        |> Repo.insert()
      end
    end)
  end

  defp normalize_response(response) do
    object = response |> extract(:object) |> stringify_keys()
    usage = response |> extract(:usage) || %{}
    text = extract(response, :text) || extract(response, :response_text)
    citations = object["citations"] || []
    markdown = object["markdown"] || text || ""
    summary = object["summary"] || String.slice(markdown, 0, 280)

    %{
      object: object,
      usage: usage,
      text: text,
      markdown: markdown,
      confidence: object["confidence"] || 0.9,
      citations: citations,
      summary: summary
    }
  end

  defp fallback_payload(section_template, context) do
    body =
      context[:documents]
      |> Enum.map(fn doc ->
        "- #{doc["summary"]} [#{doc["mock_id"] || doc["label"]}]"
      end)
      |> Enum.join("\n")

    %{
      "title" => section_template.title,
      "summary" => "Auto-generated summary based on available documents.",
      "markdown" => "### #{section_template.title}\n\n#{body}",
      "citations" =>
        Enum.map(context[:documents], fn doc ->
          %{"label" => doc["label"], "document_reference" => doc["mock_id"]}
        end)
    }
  end

  defp decode_schema(nil), do: []

  defp decode_schema(%{"fields" => fields}) when is_list(fields) do
    Enum.map(fields, &decode_field/1)
  end

  defp decode_schema(schema) when is_list(schema) do
    Enum.map(schema, &decode_field/1)
  end

  defp decode_field(%{"name" => name} = field) do
    type = field["type"] || "string"

    opts =
      []
      |> maybe_put_required(field)
      |> maybe_put_items(field)
      |> Keyword.put(:type, type_atom(type))

    {String.to_atom(name), opts}
  end

  defp maybe_put_required(opts, %{"required" => true}), do: Keyword.put(opts, :required, true)
  defp maybe_put_required(opts, _), do: opts

  defp maybe_put_items(opts, %{"items" => items}) do
    Keyword.put(opts, :items, decode_field(Map.put(items, "name", "item")) |> elem(1))
  end

  defp maybe_put_items(opts, _), do: opts

  defp type_atom("list"), do: :list
  defp type_atom("map"), do: :map
  defp type_atom("string"), do: :string
  defp type_atom("float"), do: :float
  defp type_atom(_), do: :string

  defp duration_ms(start_time) do
    System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
  end

  defp extract(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp stringify_keys(nil), do: %{}

  defp stringify_keys(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.into(%{})
  end

  defp documents_summary(docs) do
    docs
    |> Enum.map(fn doc -> "* #{doc["label"]}: #{doc["summary"]}" end)
    |> Enum.join("\n")
  end

  defp documents_text(docs) do
    docs
    |> Enum.map(fn doc ->
      """
      [#{doc["label"]}]
      #{doc["content"]}
      """
    end)
    |> Enum.join("\n\n")
  end

  defp build_name(profile) do
    Enum.filter([profile.given_name, profile.family_name], & &1)
    |> Enum.join(" ")
  end

  defp doc_label(%DocumentUpload{metadata: metadata}) do
    (metadata && (metadata["label"] || metadata["mock_id"])) || "doc"
  end

  defp symbolize_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_existing_atom(k), v} end)
    |> Enum.into(%{})
  end

  defp symbolize_keys(value), do: value

  defp to_existing_atom(key) when is_atom(key), do: key

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> String.to_atom(key)
  end
end
