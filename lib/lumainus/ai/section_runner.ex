defmodule Lumainus.AI.SectionRunner do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Lumainus.AI
  alias Lumainus.AI.LlmInvocation
  alias Lumainus.Documents.DocumentUpload
  alias Lumainus.Repo

  alias Lumainus.Reports.{ReportSectionCitation, ReportSectionRun}
  require EEx
  require Logger

  @system_prompt """
  You are Lumainus, a clinical documentation system. Produce structured markdown with inline citations like [doc-001] and return JSON that matches the provided schema exactly.
  """

  def run_section(scope, %ReportSectionRun{} = section_run, patient, documents, _opts \\ []) do
    section_run =
      Repo.preload(section_run, [
        :section_template,
        report_run: [:template]
      ])

    section_template = section_run.section_template
    doc_payloads = Enum.map(documents, &document_payload/1)
    prompt_context = build_prompt_context(section_template, patient, doc_payloads)

    prompt_text =
      render_prompt(section_template.prompt_template, prompt_context, section_template.title)

    schema = schema_to_json(section_template.output_schema)
    model_spec = AI.model_spec(section_template)

    options =
      AI.options(section_template)
      |> Keyword.put(:prompt_context, prompt_context)

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
      section_run
      |> ReportSectionRun.changeset(%{
        status: "running",
        prompt_inputs: prompt_context,
        llm_invocation_id: llm.id
      })
      |> Repo.update!()

    started = System.monotonic_time()

    case invoke_llm(model_spec, prompt_text, schema, options) do
      {:ok, response} ->
        duration = duration_ms(started)
        normalized = normalize_response(response)

        {:ok,
         persist_success(section_run, llm, normalized, prompt_context, doc_payloads, duration)}

      {:error, reason} ->
        duration = duration_ms(started)
        fallback = fallback_payload(section_template, prompt_context)

        {:error,
         persist_failure(
           section_run,
           llm,
           reason,
           fallback,
           prompt_context,
           doc_payloads,
           duration
         )}
    end
  end

  defp build_prompt_context(section_template, patient, documents) do
    profile = Map.get(patient, :current_profile) || %{}

    %{
      section_title: section_template.title,
      patient: %{
        full_name: build_name(profile),
        mrn: profile.mrn || "unknown",
        date_of_birth: profile.date_of_birth && Date.to_iso8601(profile.date_of_birth),
        sex: profile.sex
      },
      documents: documents,
      documents_summary: documents_summary(documents),
      documents_text: documents_text(documents)
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
    messages = [
      %{role: :system, content: @system_prompt},
      %{role: :user, content: prompt_text}
    ]

    AI.client().generate_object(model_spec, messages, schema, options)
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp persist_success(section_run, llm, normalized, prompt_context, documents, duration) do
    llm_attrs =
      %{
        response_text: normalized.text,
        response_object: normalized.object,
        usage: normalized.usage,
        status: "completed",
        req_duration_ms: duration
      }
      |> maybe_put_request(normalized.request_id)

    Repo.update!(Changeset.change(llm, llm_attrs))

    section_run =
      Repo.update!(
        Changeset.change(section_run, %{
          status: "completed",
          output_markdown: normalized.markdown,
          output_object: normalized.object,
          confidence_score: normalized.confidence,
          inline_citations: wrap_citations(normalized.citations),
          error: nil
        })
      )

    persist_citations(section_run, normalized.citations, documents, prompt_context)
    section_run
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

    section_run =
      Repo.update!(
        Changeset.change(section_run, %{
          status: "error",
          output_markdown: fallback["markdown"],
          output_object: fallback,
          inline_citations: wrap_citations(fallback["citations"]),
          error: error_payload
        })
      )

    persist_citations(section_run, fallback["citations"], documents, prompt_context)
    section_run
  end

  defp maybe_put_request(attrs, nil), do: attrs
  defp maybe_put_request(attrs, request_id), do: Map.put(attrs, :request_id, request_id)

  defp persist_citations(_section_run, nil, _documents, _context), do: :ok

  defp persist_citations(section_run, citations, documents, prompt_context) do
    {by_id, by_mock} = build_document_lookup(documents)

    Enum.each(citations, fn citation ->
      with {:ok, doc} <- locate_document(by_id, by_mock, citation),
           {:ok, {line_start, line_end}} <- citation_line_span(citation, doc),
           chunk <- find_chunk_for_line(doc, line_start),
           source_span <- build_source_span(doc, chunk, line_start, line_end, prompt_context) do
        %ReportSectionCitation{}
        |> ReportSectionCitation.changeset(%{
          section_run_id: section_run.id,
          document_id: doc["id"],
          document_chunk_id: chunk && chunk["chunk_id"],
          citation_label: citation["label"] || doc["label"] || doc["mock_id"] || "doc",
          source_span: source_span
        })
        |> Repo.insert()
      end
    end)
  end

  defp build_document_lookup(documents) do
    by_id = Map.new(documents, fn doc -> {doc["id"], doc} end)

    by_mock =
      documents
      |> Enum.filter(& &1["mock_id"])
      |> Map.new(fn doc -> {doc["mock_id"], doc} end)

    {by_id, by_mock}
  end

  defp locate_document(by_id, by_mock, citation) do
    reference = citation["document_reference"]

    cond do
      reference && Map.has_key?(by_mock, reference) ->
        {:ok, Map.fetch!(by_mock, reference)}

      citation["document_id"] && Map.has_key?(by_id, citation["document_id"]) ->
        {:ok, Map.fetch!(by_id, citation["document_id"])}

      true ->
        {:error, :document_not_found}
    end
  end

  defp citation_line_span(citation, doc) do
    line_start =
      citation["line_start"] ||
        parse_line_hint(citation["document_reference"]) ||
        first_line_number(doc)

    line_end = citation["line_end"] || line_start

    if line_start do
      {:ok, {line_start, line_end}}
    else
      {:error, :missing_line}
    end
  end

  defp first_line_number(doc) do
    doc["lines"]
    |> List.first()
    |> case do
      nil -> nil
      line -> line["line_start"] || 1
    end
  end

  defp find_chunk_for_line(doc, line_start) do
    (doc["lines"] || [])
    |> Enum.find(fn line ->
      start = line["line_start"]
      finish = line["line_end"] || start
      start && line_start && line_start >= start && line_start <= finish
    end) ||
      List.first(doc["lines"] || [])
  end

  defp build_source_span(doc, chunk, line_start, line_end, prompt_context) do
    %{
      "mock_id" => doc["mock_id"],
      "line_start" => line_start,
      "line_end" => line_end,
      "chunk_id" => chunk && chunk["chunk_id"],
      "excerpt" => chunk_excerpt(chunk),
      "context" => prompt_context[:section_title]
    }
  end

  defp chunk_excerpt(nil), do: nil

  defp chunk_excerpt(chunk) do
    chunk["content"]
    |> to_string()
    |> String.trim()
    |> String.slice(0, 280)
  end

  defp parse_line_hint(nil), do: nil

  defp parse_line_hint(reference) when is_binary(reference) do
    case Regex.run(~r/L(\d+)/, reference) do
      [_, number] -> String.to_integer(number)
      _ -> nil
    end
  end

  defp parse_line_hint(_), do: nil

  defp wrap_citations(nil), do: %{"entries" => []}
  defp wrap_citations(citations) when is_list(citations), do: %{"entries" => citations}
  defp wrap_citations(other), do: other

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
      summary: summary,
      request_id: extract(response, :request_id)
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
          %{
            "label" => doc["label"],
            "document_reference" => doc["mock_id"],
            "document_id" => doc["id"],
            "line_start" => 1,
            "line_end" => 1
          }
        end)
    }
  end

  @doc false
  def schema_to_json(schema), do: decode_schema(schema)

  defp decode_schema(nil), do: nil

  defp decode_schema(%{"type" => _} = schema), do: schema

  defp decode_schema(%{"fields" => fields}) when is_list(fields) do
    build_object_schema(fields)
  end

  defp decode_schema(%{"fields" => %{} = nested}) do
    inner_fields = Map.get(nested, "fields") || Map.get(nested, :fields) || []
    decode_schema(%{"fields" => inner_fields})
  end

  defp decode_schema(fields) when is_list(fields) do
    build_object_schema(fields)
  end

  defp build_object_schema(fields) do
    normalized_fields = Enum.map(fields, &normalize_field/1)

    {properties, required} =
      Enum.reduce(normalized_fields, {%{}, []}, fn field, {props, req} ->
        name = field_name(field)
        schema = field_schema(field)
        updated_props = Map.put(props, name, schema)

        updated_req =
          if truthy?(field["required"] || field[:required]) do
            [name | req]
          else
            req
          end

        {updated_props, updated_req}
      end)

    schema = %{"type" => "object", "properties" => properties}

    case required do
      [] -> schema
      req_list -> Map.put(schema, "required", Enum.reverse(req_list))
    end
  end

  defp field_schema(field) do
    case field_type(field) do
      "list" ->
        items = Map.get(field, "items") || Map.get(field, :items)
        %{"type" => "array", "items" => normalize_item_schema(items)}

      "map" ->
        nested = Map.get(field, "fields") || Map.get(field, :fields) || []
        decode_schema(%{"fields" => nested})

      "float" ->
        %{"type" => "number"}

      "integer" ->
        %{"type" => "integer"}

      "boolean" ->
        %{"type" => "boolean"}

      _ ->
        %{"type" => "string"}
    end
  end

  defp normalize_item_schema(nil), do: %{"type" => "string"}

  defp normalize_item_schema(%{} = item) do
    item
    |> normalize_map_keys()
    |> Map.put_new("type", item["type"] || item[:type] || "string")
    |> Map.put_new("name", item["name"] || item[:name] || "item")
    |> field_schema()
  end

  defp normalize_item_schema(item) when is_list(item) do
    cond do
      keyword_schema_opts?(item) ->
        item
        |> normalize_field_opts()
        |> Map.put_new("type", item[:type] || "string")
        |> field_schema()

      true ->
        %{"type" => "object", "fields" => Enum.map(item, &normalize_field/1)}
    end
  end

  defp field_name(field) do
    cond do
      name = field["name"] -> name
      name = field[:name] -> name
      true -> "field_#{System.unique_integer([:positive])}"
    end
  end

  defp field_type(field) do
    field["type"] || field[:type] || "string"
  end

  defp normalize_field(%{} = field) do
    field
    |> normalize_map_keys()
    |> maybe_normalize_nested("fields")
    |> maybe_normalize_nested("items")
  end

  defp normalize_field({name, opts}) when is_atom(name) or is_binary(name) do
    base =
      %{}
      |> Map.put("name", to_string(name))
      |> Map.merge(normalize_field_opts(opts))

    base
  end

  defp normalize_field(other) do
    %{
      "name" => "field_#{System.unique_integer([:positive])}",
      "type" => "string",
      "value" => other
    }
  end

  defp normalize_field_opts(nil), do: %{}

  defp normalize_field_opts(%{} = opts) do
    opts
    |> normalize_map_keys()
    |> maybe_normalize_nested("fields")
    |> maybe_normalize_nested("items")
  end

  defp normalize_field_opts(opts) when is_list(opts) do
    Enum.reduce(opts, %{}, fn
      {:type, type}, acc ->
        info = parse_type_info(type)

        acc
        |> maybe_put("type", info[:type])
        |> maybe_put("items", normalize_value_schema(info[:items]))
        |> maybe_put("fields", normalize_fields(info[:fields]))

      {:items, value}, acc ->
        acc
        |> Map.put("type", "list")
        |> Map.put("items", normalize_value_schema(value))

      {:fields, value}, acc ->
        Map.put(acc, "fields", normalize_fields(value))

      {:keys, value}, acc ->
        Map.put(acc, "fields", normalize_fields(value))

      {:required, value}, acc ->
        if truthy?(value), do: Map.put(acc, "required", true), else: acc

      {key, value}, acc ->
        Map.put(acc, normalize_key(key), value)
    end)
  end

  defp parse_type_info({:list, inner}), do: %{type: "list", items: inner}
  defp parse_type_info({:map, inner}), do: %{type: "map", fields: inner}
  defp parse_type_info(type) when is_atom(type), do: %{type: Atom.to_string(type)}
  defp parse_type_info(type) when is_binary(type), do: %{type: type}
  defp parse_type_info(_), do: %{type: "string"}

  defp normalize_value_schema(nil), do: nil

  defp normalize_value_schema({:list, inner}) do
    %{"type" => "array", "items" => normalize_value_schema(inner)}
  end

  defp normalize_value_schema({:map, inner}) do
    %{"type" => "object"}
    |> maybe_put("fields", normalize_fields(inner))
  end

  defp normalize_value_schema(value) when is_list(value) do
    if keyword_schema_opts?(value) do
      normalize_field_opts(value)
    else
      %{"type" => "object"}
      |> maybe_put("fields", normalize_fields(value))
    end
  end

  defp normalize_value_schema(%{} = value) do
    normalize_map_keys(value)
    |> maybe_normalize_nested("fields")
    |> maybe_normalize_nested("items")
  end

  defp normalize_value_schema(value) when is_atom(value) do
    %{"type" => Atom.to_string(value)}
  end

  defp normalize_value_schema(value) when is_binary(value) do
    %{"type" => value}
  end

  defp normalize_value_schema(value), do: %{"type" => "string", "value" => value}

  defp normalize_fields(nil), do: nil

  defp normalize_fields(fields) when is_list(fields) do
    Enum.map(fields, &normalize_field/1)
  end

  defp normalize_fields(%{} = map) do
    inner = Map.get(map, "fields") || Map.get(map, :fields)
    normalize_fields(inner)
  end

  defp normalize_fields(_), do: nil

  defp normalize_map_keys(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, normalize_key(key), value)
    end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp maybe_normalize_nested(map, key) do
    cond do
      Map.has_key?(map, key) ->
        Map.update!(map, key, &normalize_value_schema/1)

      Map.has_key?(map, String.to_atom(key)) ->
        atom_key = String.to_atom(key)
        value = Map.get(map, atom_key)

        map
        |> Map.delete(atom_key)
        |> Map.put(key, normalize_value_schema(value))

      true ->
        map
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp keyword_schema_opts?(list) do
    Enum.all?(list, fn
      {key, _value} when is_atom(key) or is_binary(key) -> true
      _ -> false
    end)
  end

  defp truthy?(value), do: value not in [nil, false]

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

  defp document_payload(%DocumentUpload{} = doc) do
    metadata = doc.metadata || %{}
    parse = List.first(doc.parses || [])

    %{
      "id" => doc.id,
      "mock_id" => metadata["mock_id"] || doc_label(doc),
      "label" => doc_label(doc),
      "summary" => metadata["summary"] || "Awaiting ingestion",
      "kind" => doc.document_kind,
      "provider" => metadata["provider"] || "Unknown source",
      "lines" => document_lines(parse, doc)
    }
  end

  defp document_lines(nil, doc), do: fallback_lines(doc)

  defp document_lines(%{} = parse, doc) do
    chunks = Map.get(parse, :chunks, [])

    cond do
      is_list(chunks) and chunks != [] ->
        Enum.map(chunks, fn chunk ->
          %{
            "chunk_id" => chunk.id,
            "line_start" => chunk.line_start || chunk.position || 1,
            "line_end" => chunk.line_end || chunk.line_start || chunk.position || 1,
            "content" => chunk.content || ""
          }
        end)

      parse[:parsed_text] ->
        parse.parsed_text
        |> to_string()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reduce([], fn {line, idx}, acc ->
          trimmed = String.trim(line)

          if trimmed == "" do
            acc
          else
            [
              %{"chunk_id" => nil, "line_start" => idx, "line_end" => idx, "content" => trimmed}
              | acc
            ]
          end
        end)
        |> Enum.reverse()
        |> case do
          [] -> fallback_lines(doc)
          lines -> lines
        end

      true ->
        fallback_lines(doc)
    end
  end

  defp fallback_lines(doc) do
    summary = (doc.metadata && doc.metadata["summary"]) || "Awaiting ingestion"

    [
      %{
        "chunk_id" => nil,
        "line_start" => 1,
        "line_end" => 1,
        "content" => summary
      }
    ]
  end

  defp documents_summary(docs) do
    docs
    |> Enum.map(fn doc -> "* #{doc["label"]}: #{doc["summary"]}" end)
    |> Enum.join("\n")
  end

  defp documents_text(docs) do
    docs
    |> Enum.map(fn doc ->
      lines =
        (doc["lines"] || [])
        |> Enum.map(fn line ->
          "#{line_reference(doc, line)} #{line["content"]}"
        end)
        |> Enum.join("\n")

      """
      [#{doc["label"]} · #{doc["mock_id"]}]
      #{lines}
      """
    end)
    |> Enum.join("\n\n")
  end

  defp line_reference(doc, line) do
    mock = doc["mock_id"] || doc["label"] || "doc"
    line_start = line["line_start"] || 1
    line_end = line["line_end"] || line_start

    label =
      if line_start == line_end do
        "L#{pad_line(line_start)}"
      else
        "L#{pad_line(line_start)}-L#{pad_line(line_end)}"
      end

    "[#{mock}:#{label}]"
  end

  defp pad_line(line) when is_integer(line) do
    line
    |> Integer.to_string()
    |> String.pad_leading(3, "0")
  end

  defp pad_line(_), do: "000"

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
