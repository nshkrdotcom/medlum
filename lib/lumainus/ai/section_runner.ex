defmodule Lumainus.AI.SectionRunner do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Lumainus.AI
  alias Lumainus.AI.LlmInvocation
  alias Lumainus.Documents.DocumentUpload
  alias Lumainus.Repo

  alias Lumainus.Reports.{ReportSectionCitation, ReportSectionRun}
  alias JsonRemedy
  require EEx
  require Logger

  def run_section(scope, %ReportSectionRun{} = section_run, patient, documents, _opts \\ []) do
    section_run =
      Repo.preload(section_run, [
        :section_template,
        report_run: [:template]
      ])

    section_template = section_run.section_template
    template = section_run.report_run.template
    report_run = section_run.report_run
    doc_payloads = Enum.map(documents, &document_payload/1)

    # Check if we have a cached context for this report run
    cached_content_name = report_run.cached_content_name

    # Build context differently based on whether we're using cache
    prompt_context =
      if cached_content_name do
        # With cache: documents are in the cache, don't include full text in prompt
        build_prompt_context_cached(section_template, patient, doc_payloads)
      else
        # Without cache: include full document context in prompt
        build_prompt_context(section_template, patient, doc_payloads)
      end

    prompt_text =
      render_prompt(section_template.prompt_template, prompt_context, section_template.title)

    schema = schema_for_llm(section_template.output_schema)

    # When using cache, use the cache model; otherwise use section-configured model
    model_spec =
      if cached_content_name do
        # Override to use cache-compatible model
        cache_model = Lumainus.Reports.CacheManager.cache_model()
        "google:#{cache_model}"
      else
        AI.model_spec(section_template)
      end

    {provider_used, model_used} = resolve_provider_model(model_spec, section_template)

    # Get system prompt with proper precedence: section → template → default
    # When using cache, system_prompt is already in the cache
    system_prompt =
      if cached_content_name do
        nil
      else
        AI.system_prompt(section_template, template)
      end

    # Get merged options with proper precedence: section → template defaults → app config
    options =
      AI.options(section_template, template)
      |> Keyword.put(:prompt_context, prompt_context)
      |> maybe_put_kw(:system_instruction, system_prompt)
      |> maybe_put_kw(:cached_content, cached_content_name)

    llm =
      %LlmInvocation{}
      |> LlmInvocation.changeset(%{
        tenant_id: scope.tenant_id,
        provider: provider_used,
        model: model_used,
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

  # Build context when using cache - documents are in the cache, not the prompt
  defp build_prompt_context_cached(section_template, patient, documents) do
    profile = Map.get(patient, :current_profile) || %{}

    %{
      section_title: section_template.title,
      patient: %{
        full_name: build_name(profile),
        mrn: profile.mrn || "unknown",
        date_of_birth: profile.date_of_birth && Date.to_iso8601(profile.date_of_birth),
        sex: profile.sex
      },
      # Include document metadata for citations, but not full text (it's in cache)
      documents: documents,
      documents_summary: documents_summary(documents),
      # When using cache, documents_text is stored in cached context
      documents_text:
        "[Documents provided via Gemini cached content. Use the labels above for citations.]"
    }
  end

  # Helper to conditionally put a key-value pair (don't put nil values)
  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, key, value), do: Keyword.put(opts, key, value)

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
    AI.client().generate_object(model_spec, prompt_text, schema, options)
  rescue
    error ->
      {:error, %{type: :exception, message: Exception.message(error), exception: inspect(error)}}
  end

  defp persist_success(section_run, llm, normalized, prompt_context, documents, duration) do
    llm_attrs =
      %{
        response_text: normalized.text,
        response_object: normalized.object,
        usage: normalized.usage,
        status: "completed",
        req_duration_ms: duration,
        repair_status: normalized.repair_status,
        finish_reason: normalized.finish_reason,
        has_content: normalized.has_content,
        parts_count: normalized.parts_count
      }
      |> maybe_put_request(normalized.request_id)

    Repo.update!(Changeset.change(llm, llm_attrs))

    # Clear error field on success (should always be nil now)
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
    error_payload = failure_error_payload(reason)

    # Log with structured error info
    Logger.error("""
    [SectionRunner] LLM generation failed for section_run=#{section_run.id}
    Section: #{section_run.section_template.title}
    Error: #{inspect(error_payload)}
    """)

    # Update LLM invocation with error status AND error details
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
    lookups = build_document_lookup(documents)

    Enum.each(citations, fn citation ->
      with {:ok, doc} <- locate_document(lookups, citation),
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

    by_label =
      documents
      |> Enum.filter(& &1["label"])
      |> Map.new(fn doc -> {normalize_label(doc["label"]), doc} end)

    {by_id, by_mock, by_label}
  end

  defp locate_document({by_id, by_mock, by_label}, citation) do
    reference = citation["document_reference"]
    label = citation["label"]
    norm_ref = normalize_label(reference)
    norm_label = normalize_label(label)

    cond do
      reference && Map.has_key?(by_mock, reference) ->
        {:ok, Map.fetch!(by_mock, reference)}

      citation["document_id"] && Map.has_key?(by_id, citation["document_id"]) ->
        {:ok, Map.fetch!(by_id, citation["document_id"])}

      norm_ref && Map.has_key?(by_label, norm_ref) ->
        {:ok, Map.fetch!(by_label, norm_ref)}

      norm_label && Map.has_key?(by_label, norm_label) ->
        {:ok, Map.fetch!(by_label, norm_label)}

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
    raw_object = response |> extract(:object) |> stringify_keys()
    usage = response |> extract(:usage) || %{}
    text = extract(response, :text) || extract(response, :response_text)

    # Get repair_status from LLM response (LLM.ex now handles JSON repair)
    repair_status_from_llm = extract(response, :repair_status) || "none"

    # Get response metadata from LLM (for debugging empty responses)
    finish_reason = extract(response, :finish_reason)
    has_content = extract(response, :has_content)
    parts_count = extract(response, :parts_count)

    # Defensive passthrough: object should already be decoded by LLM.ex
    # This handles edge cases where object might still be a binary
    {object, repair_status_from_object} = ensure_decoded_object(raw_object, text)

    # Handle nested JSON: if markdown field contains JSON with a markdown key, extract it
    # This handles the case where LLM wraps response in {"markdown": "{...actual json...}"}
    {markdown, citations, summary, repair_status_from_nested} =
      extract_content_from_object(object, text)

    # Determine final repair status (LLM's status takes precedence, then object, then nested)
    repair_status =
      cond do
        repair_status_from_llm != "none" -> repair_status_from_llm
        repair_status_from_object != "none" -> repair_status_from_object
        repair_status_from_nested != "none" -> repair_status_from_nested
        true -> "none"
      end

    %{
      object: object,
      usage: usage,
      text: text,
      markdown: markdown,
      confidence: object["confidence"] || 0.9,
      citations: citations,
      summary: summary,
      request_id: extract(response, :request_id),
      repair_status: repair_status,
      finish_reason: finish_reason,
      has_content: has_content,
      parts_count: parts_count
    }
  end

  # Extract markdown, citations, and summary from object, handling nested JSON in markdown field
  defp extract_content_from_object(object, text) when is_map(object) do
    raw_markdown = object["markdown"] || text || ""

    # Check if markdown field contains JSON (LLM returned nested JSON)
    case maybe_decode_nested_json(raw_markdown) do
      {:ok, nested, repair_status} when is_map(nested) ->
        # Successfully decoded nested JSON - extract fields from it
        markdown = nested["markdown"] || raw_markdown
        citations = nested["citations"] || object["citations"] || []
        summary = nested["summary"] || object["summary"] || String.slice(markdown, 0, 280)
        {markdown, citations, summary, repair_status}

      _ ->
        # Normal case - use fields directly from object
        citations = object["citations"] || []
        summary = object["summary"] || String.slice(raw_markdown, 0, 280)
        {raw_markdown, citations, summary, "none"}
    end
  end

  defp extract_content_from_object(_, text),
    do: {text || "", [], String.slice(text || "", 0, 280), "none"}

  # Try to decode a string as JSON if it looks like JSON
  defp maybe_decode_nested_json(str) when is_binary(str) do
    trimmed = String.trim(str)

    if String.starts_with?(trimmed, "{") do
      case Jason.decode(trimmed) do
        {:ok, decoded} ->
          # Jason decoded successfully - no repair needed
          {:ok, decoded, "none"}

        _ ->
          # Use JsonRemedy for tolerant repair of malformed JSON (trailing junk, missing braces)
          case JsonRemedy.repair(trimmed, fast_path_optimization: false, logging: true) do
            {:ok, decoded, logs} when is_list(logs) ->
              # JsonRemedy with logs - check if repairs were made
              repair_status = if length(logs) > 0, do: "repaired", else: "none"
              {:ok, decoded, repair_status}

            {:ok, decoded} ->
              # JsonRemedy without logs - assume repair happened since Jason failed
              {:ok, decoded, "repaired"}

            {:error, _reason} ->
              # JsonRemedy failed to repair
              :not_json
          end
      end
    else
      :not_json
    end
  end

  defp maybe_decode_nested_json(_), do: :not_json

  # Object should already be decoded by LLM.ex - this is defensive handling
  # for edge cases where object might still be a binary string
  defp ensure_decoded_object(object, _text) when is_binary(object) do
    trimmed = String.trim(object)

    case Jason.decode(trimmed) do
      {:ok, decoded} when is_map(decoded) ->
        {stringify_keys(decoded), "none"}

      _ ->
        # Try JsonRemedy as last resort
        case JsonRemedy.repair(trimmed, fast_path_optimization: false, logging: true) do
          {:ok, repaired, logs} when is_list(logs) ->
            status = if length(logs) > 0, do: "repaired", else: "none"
            {stringify_keys(repaired), status}

          {:ok, repaired} ->
            {stringify_keys(repaired), "repaired"}

          {:error, _} ->
            # All repair attempts failed - wrap in markdown and mark as failed
            {%{"markdown" => object}, "failed"}
        end
    end
  end

  # Object is nil but text might contain JSON - try to decode it
  defp ensure_decoded_object(nil, text) when is_binary(text) and text != "" do
    trimmed = String.trim(text)

    if String.starts_with?(trimmed, "{") do
      case Jason.decode(trimmed) do
        {:ok, decoded} when is_map(decoded) ->
          {stringify_keys(decoded), "none"}

        _ ->
          case JsonRemedy.repair(trimmed, fast_path_optimization: false, logging: true) do
            {:ok, repaired, logs} when is_list(logs) ->
              status = if length(logs) > 0, do: "repaired", else: "none"
              {stringify_keys(repaired), status}

            {:ok, repaired} ->
              {stringify_keys(repaired), "repaired"}

            {:error, _} ->
              {%{"markdown" => text}, "failed"}
          end
      end
    else
      {%{"markdown" => text}, "none"}
    end
  end

  # Object is already a map - pass through
  defp ensure_decoded_object(object, _text) when is_map(object), do: {object, "none"}

  # Fallback for nil/empty cases
  defp ensure_decoded_object(nil, _), do: {%{}, "none"}
  defp ensure_decoded_object(_, _), do: {%{}, "none"}

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

  defp failure_error_payload(reason) when is_binary(reason), do: %{"message" => reason}

  # Handle Gemini.Error struct with rich error info
  defp failure_error_payload(%Gemini.Error{} = error) do
    %{
      "type" => to_string(error.type),
      "message" => error.message,
      "http_status" => error.http_status,
      "api_reason" => stringify_if_present(error.api_reason),
      "details" => error.details,
      "original_error" => stringify_if_present(error.original_error)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Handle other structs (exceptions, etc.)
  defp failure_error_payload(%{__struct__: module} = reason) do
    message =
      if function_exported?(module, :message, 1) do
        Exception.message(reason)
      else
        inspect(reason)
      end

    base = %{
      "message" => message,
      "type" => to_string(module)
    }

    # Try to extract common fields if present
    base
    |> maybe_add_field("http_status", Map.get(reason, :http_status))
    |> maybe_add_field("details", Map.get(reason, :details))
  end

  # Handle plain maps (including our rescue-wrapped errors)
  defp failure_error_payload(reason) when is_map(reason) do
    message = Map.get(reason, "message") || Map.get(reason, :message) || inspect(reason)

    %{"message" => message}
    |> maybe_add_field("type", Map.get(reason, :type) || Map.get(reason, "type"))
    |> maybe_add_field(
      "http_status",
      Map.get(reason, :http_status) || Map.get(reason, "http_status")
    )
    |> maybe_add_field(
      "api_reason",
      Map.get(reason, :api_reason) || Map.get(reason, "api_reason")
    )
    |> maybe_add_field("details", Map.get(reason, :details) || Map.get(reason, "details"))
    |> maybe_add_field("exception", Map.get(reason, :exception) || Map.get(reason, "exception"))
  end

  defp failure_error_payload(reason), do: %{"message" => inspect(reason)}

  defp stringify_if_present(nil), do: nil
  defp stringify_if_present(val) when is_binary(val), do: val
  defp stringify_if_present(val) when is_atom(val), do: to_string(val)
  defp stringify_if_present(val), do: inspect(val)

  defp maybe_add_field(map, _key, nil), do: map
  defp maybe_add_field(map, key, value), do: Map.put(map, key, value)

  @doc false
  def schema_to_json(schema), do: decode_schema(schema)

  @doc false
  def schema_for_llm(schema) do
    schema
    |> schema_to_json()
    |> ensure_array_items()
  end

  # Runtime normalization: ensure all array fields have an "items" property.
  # Gemini's structured output API requires this. This is a safety net for any
  # schemas that weren't fixed by migration or were created incorrectly.
  defp ensure_array_items(nil), do: nil

  defp ensure_array_items(%{"type" => "object", "properties" => props} = schema)
       when is_map(props) do
    fixed_props =
      Enum.reduce(props, %{}, fn {key, value}, acc ->
        Map.put(acc, key, ensure_array_items_for_field(key, value))
      end)

    Map.put(schema, "properties", fixed_props)
  end

  defp ensure_array_items(schema), do: schema

  defp ensure_array_items_for_field(field_name, %{"type" => "array"} = field) do
    if Map.has_key?(field, "items") do
      field
    else
      Map.put(field, "items", default_items_schema(field_name))
    end
  end

  defp ensure_array_items_for_field(_field_name, field), do: field

  @citations_items_schema %{
    "type" => "object",
    "properties" => %{
      "label" => %{"type" => "string"},
      "document_id" => %{"type" => "string"},
      "document_reference" => %{"type" => "string"},
      "line_start" => %{"type" => "integer"},
      "line_end" => %{"type" => "integer"},
      "excerpt" => %{"type" => "string"}
    }
  }

  defp default_items_schema("citations"), do: @citations_items_schema
  defp default_items_schema(_), do: %{"type" => "string"}

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
    parse = if Ecto.assoc_loaded?(doc.parses), do: List.first(doc.parses), else: nil

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

      parsed = Map.get(parse, :parsed_text) ->
        parsed
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

  defp resolve_provider_model(model_spec, section_template) do
    case String.split(to_string(model_spec), ":", parts: 2) do
      [provider, model] when provider != "" and model != "" ->
        {provider, model}

      _ ->
        fallback = AI.model_spec(section_template)

        case String.split(fallback, ":", parts: 2) do
          [provider, model] -> {provider, model}
          _ -> {section_template.provider || "google", section_template.model || "unknown"}
        end
    end
  end

  defp normalize_label(nil), do: nil

  defp normalize_label(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
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
