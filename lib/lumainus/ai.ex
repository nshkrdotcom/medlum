defmodule Lumainus.AI do
  @moduledoc """
  Central configuration and helper utilities for LLM integrations.

  ## Precedence Rules

  LLM options are merged with the following precedence (highest to lowest):
  1. Section-level fields (from `ReportSectionTemplate`)
  2. Template-level defaults (from `ReportTemplate.default_prompt_options`)
  3. Application config (from `:lumainus, :llm, :default_options`)

  This allows fine-grained control at the section level while providing
  sensible defaults at the template and application levels.
  """

  alias Lumainus.Reports.{ReportSectionTemplate, ReportTemplate}

  @doc """
  Returns the LLM client module configured for the application.
  """
  def client do
    config()
    |> Keyword.get(:client, Lumainus.LLM)
  end

  @doc """
  Returns the model specification string for the given section template.

  Format: "provider:model" (e.g., "google:gemini-2.0-flash")
  """
  def model_spec(section_template \\ nil) do
    provider = section_template && section_template.provider
    model = section_template && section_template.model

    provider = provider || Keyword.get(config(), :default_provider, "google")
    model = model || Keyword.get(config(), :default_model, "gemini-flash-lite-latest")

    "#{provider}:#{model}"
  end

  @doc """
  Returns the fallback model specification if configured, otherwise nil.

  Falls back to section-level fallback_provider/fallback_model if set.
  """
  def fallback_model_spec(section_template) do
    provider = section_template && section_template.fallback_provider
    model = section_template && section_template.fallback_model

    if provider && model do
      "#{provider}:#{model}"
    else
      nil
    end
  end

  @doc """
  Returns merged LLM options with proper precedence.

  Options include all Gemini-supported parameters:
  - Sampling: temperature, top_p, top_k, candidate_count
  - Limits: max_output_tokens
  - Penalties: presence_penalty, frequency_penalty
  - Control: stop_sequences, seed
  - Reliability: timeout_ms, max_retries, retry_delay_ms
  - Output: response_mime_type
  - Context: system_instruction (from system_prompt)

  ## Precedence (highest to lowest)
  1. Section-level values from section_template
  2. Template-level defaults from template.default_prompt_options
  3. Application config from :lumainus, :llm, :default_options
  """
  def options(section_template \\ nil, template \\ nil) do
    # Start with application defaults
    app_opts = Keyword.get(config(), :default_options, [])

    # Merge template defaults (if template provided)
    template_opts = extract_template_defaults(template)
    merged = merge_opts(app_opts, template_opts)

    # Merge section-level overrides
    section_opts = extract_section_opts(section_template)
    merge_opts(merged, section_opts)
  end

  @doc """
  Returns the system prompt with proper precedence.

  Order (highest to lowest):
  1. Section-level system_prompt (if not nil)
  2. Template-level system_prompt (if not nil)
  3. Default from Blueprints.default_system_prompt()
  """
  def system_prompt(section_template, template \\ nil) do
    cond do
      section_template && section_template.system_prompt ->
        section_template.system_prompt

      template && template.system_prompt ->
        template.system_prompt

      true ->
        Lumainus.Reports.Blueprints.default_system_prompt()
    end
  end

  @doc """
  Returns whether LLM is enabled in the application config.
  """
  def enabled? do
    Keyword.get(config(), :enabled, true)
  end

  # Extract options from template.default_prompt_options map
  defp extract_template_defaults(nil), do: []

  defp extract_template_defaults(%ReportTemplate{default_prompt_options: nil}), do: []

  defp extract_template_defaults(%ReportTemplate{default_prompt_options: opts})
       when is_map(opts) do
    opts
    |> Enum.reduce([], fn
      {key, value}, acc when is_atom(key) ->
        Keyword.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        try do
          atom_key = String.to_existing_atom(key)
          Keyword.put(acc, atom_key, value)
        rescue
          ArgumentError -> acc
        end

      _other, acc ->
        acc
    end)
  end

  defp extract_template_defaults(_), do: []

  # Extract options from section template fields
  defp extract_section_opts(nil), do: []

  defp extract_section_opts(%ReportSectionTemplate{} = section) do
    []
    |> maybe_put(:temperature, section.temperature)
    |> maybe_put(:max_output_tokens, section.max_output_tokens)
    |> maybe_put(:top_p, section.top_p)
    |> maybe_put(:top_k, section.top_k)
    |> maybe_put(:candidate_count, section.candidate_count)
    |> maybe_put(:presence_penalty, section.presence_penalty)
    |> maybe_put(:frequency_penalty, section.frequency_penalty)
    |> maybe_put(:stop_sequences, non_empty_list(section.stop_sequences))
    |> maybe_put(:seed, section.seed)
    |> maybe_put(:timeout_ms, section.timeout_ms)
    |> maybe_put(:max_retries, section.max_retries)
    |> maybe_put(:retry_delay_ms, section.retry_delay_ms)
    |> maybe_put(:response_mime_type, section.response_mime_type)
  end

  defp extract_section_opts(_), do: []

  # Only include stop_sequences if non-empty list
  defp non_empty_list([]), do: nil
  defp non_empty_list(list) when is_list(list), do: list
  defp non_empty_list(_), do: nil

  # Merge two keyword lists, with second taking precedence for non-nil values
  defp merge_opts(base, overrides) do
    Enum.reduce(overrides, base, fn {key, value}, acc ->
      Keyword.put(acc, key, value)
    end)
  end

  defp config do
    Application.get_env(:lumainus, :llm, [])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
