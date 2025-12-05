defmodule Lumainus.Reports.CacheManager do
  @moduledoc """
  Manages Gemini context caches for report runs.

  When running a report with multiple sections, this module creates a single
  shared cache containing the documents and system prompt. Each section then
  uses this cache, sending only its section-specific prompt.

  ## Benefits

  - **Token reduction**: Documents are sent once (~50K-100K tokens) instead of
    per-section (~550K-1.1M for 11 sections)
  - **Cost savings**: Cached tokens are ~4x cheaper than regular tokens
  - **Rate limit friendly**: Dramatically reduces tokens per minute usage

  ## Cache Lifecycle

  1. `create_cache/4` - Called before enqueueing section jobs
  2. Section workers use `cached_content: cache_name` in requests
  3. `delete_cache/1` - Called when report completes/fails via RunReconciler

  ## Requirements

  - Model must support caching (gemini-3.0-pro-preview, gemini-2.5-pro, gemini-2.5-flash)
  - Minimum tokens required depends on model (1024-4096)

  ## Configuration

  Cache settings (model, TTL, system prompt, min tokens) are stored in the database
  and can be configured at `/admin/llm-config`. See `Lumainus.Reports.CacheSettings`.
  """

  alias Gemini.APIs.ContextCache
  alias Lumainus.Documents.DocumentUpload
  alias Lumainus.Reports.CacheSettings
  require Logger

  @doc """
  Creates a context cache for a report run.

  ## Parameters

  - `run_id` - ReportRun ID (used in display_name for identification)
  - `documents` - List of DocumentUpload structs with parses/chunks preloaded
  - `system_prompt` - System instruction to include in cache
  - `opts` - Options:
    - `:ttl` - Cache TTL in seconds (default from DB settings)
    - `:model` - Model to use for cache (default from DB settings)

  ## Returns

  - `{:ok, cache_name}` - Cache created successfully
  - `{:skip, :content_too_small}` - Documents below min token threshold for model
  - `{:error, reason}` - Failed to create cache
  """
  @spec create_cache(String.t(), [DocumentUpload.t()], String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()} | {:skip, atom()}
  def create_cache(run_id, documents, system_prompt, opts \\ []) do
    # Get configuration from database (with fallbacks)
    ttl = Keyword.get(opts, :ttl, CacheSettings.cache_ttl())
    model = Keyword.get(opts, :model, CacheSettings.cache_model())
    min_tokens = CacheSettings.min_tokens()

    # Build the cacheable content: formatted documents
    documents_text = build_documents_text(documents)

    # Create content for caching - documents go in contents, system prompt separate
    cache_contents = """
    # Patient Medical Records

    The following documents contain the patient's medical records for analysis.
    Each document is labeled with a reference ID for citation purposes.

    #{documents_text}
    """

    display_name = "lumainus-report-#{run_id}"
    estimated_tokens = estimate_tokens(cache_contents, system_prompt)

    if estimated_tokens < min_tokens do
      Logger.info(
        "[CacheManager] Skipping cache creation (too small): #{estimated_tokens} tokens (<#{min_tokens} for #{model})"
      )

      {:skip, :content_too_small}
    else
      Logger.info(
        "[CacheManager] Creating cache for run #{run_id} with #{length(documents)} documents (#{estimated_tokens} tokens est)"
      )

      case ContextCache.create(
             cache_contents,
             display_name: display_name,
             model: model,
             ttl: ttl,
             system_instruction: system_prompt
           ) do
        {:ok, cache} ->
          Logger.info("[CacheManager] Cache created: #{cache.name}")
          {:ok, cache.name}

        {:error, reason} ->
          Logger.error("[CacheManager] Failed to create cache: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Deletes a context cache.

  Safe to call even if cache doesn't exist or has already expired.

  ## Parameters

  - `cache_name` - Full cache name (e.g., "cachedContents/abc123")

  ## Returns

  - `:ok` - Cache deleted (or didn't exist)
  - `{:error, reason}` - Unexpected error
  """
  @spec delete_cache(String.t() | nil) :: :ok | {:error, term()}
  def delete_cache(nil), do: :ok

  def delete_cache(cache_name) when is_binary(cache_name) do
    Logger.info("[CacheManager] Deleting cache: #{cache_name}")

    case ContextCache.delete(cache_name) do
      :ok ->
        Logger.info("[CacheManager] Cache deleted successfully")
        :ok

      {:error, %Gemini.Error{http_status: 404}} ->
        # Cache already expired or deleted - that's fine
        Logger.debug("[CacheManager] Cache not found (already expired/deleted)")
        :ok

      {:error, reason} ->
        Logger.warning("[CacheManager] Failed to delete cache: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Returns the model that should be used with a cache.

  Reads from database settings. Ensures the generation model matches
  the cache model to avoid errors.
  """
  @spec cache_model() :: String.t()
  def cache_model, do: CacheSettings.cache_model()

  # Build the text representation of all documents
  # Matches the format used by SectionRunner.documents_text/1
  defp build_documents_text(documents) do
    documents
    |> Enum.map(&build_document_payload/1)
    |> Enum.map(&format_document/1)
    |> Enum.join("\n\n---\n\n")
  end

  defp build_document_payload(%DocumentUpload{} = doc) do
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

  defp format_document(doc) do
    lines =
      (doc["lines"] || [])
      |> Enum.map(fn line ->
        "#{line_reference(doc, line)} #{line["content"]}"
      end)
      |> Enum.join("\n")

    """
    ## [#{doc["label"]} - #{doc["mock_id"]}]
    **Type**: #{doc["kind"]} | **Source**: #{doc["provider"]}
    **Summary**: #{doc["summary"]}

    #{lines}
    """
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
        |> Enum.reject(fn {line, _} -> String.trim(line) == "" end)
        |> Enum.map(fn {line, idx} ->
          %{
            "chunk_id" => nil,
            "line_start" => idx,
            "line_end" => idx,
            "content" => String.trim(line)
          }
        end)
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

  defp doc_label(%DocumentUpload{metadata: metadata}) do
    (metadata && (metadata["label"] || metadata["mock_id"])) || "doc"
  end

  # Rough token estimate to avoid attempting tiny caches (Gemini requires 1024 tokens+)
  defp estimate_tokens(cache_contents, system_prompt) do
    total_chars =
      String.length(to_string(cache_contents)) +
        String.length(to_string(system_prompt || ""))

    # Approximate ~4 chars per token for English text
    div(total_chars, 4)
  end
end
