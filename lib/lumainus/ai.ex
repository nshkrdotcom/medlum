defmodule Lumainus.AI do
  @moduledoc """
  Central configuration and helper utilities for ReqLLM integrations.
  """

  alias Lumainus.AI.ReqLLMClient

  def client do
    config()
    |> Keyword.get(:client, ReqLLMClient)
  end

  def model_spec(section_template \\ nil) do
    provider = section_template && section_template.provider
    model = section_template && section_template.model

    provider = provider || Keyword.get(config(), :default_provider, "google")
    model = model || Keyword.get(config(), :default_model, "gemini-flash-lite-latest")

    "#{provider}:#{model}"
  end

  def options(section_template \\ nil) do
    base_opts = Keyword.get(config(), :default_options, [])

    overrides =
      []
      |> maybe_put(:temperature, section_template && section_template.temperature)
      |> maybe_put(:max_output_tokens, section_template && section_template.max_output_tokens)

    Keyword.merge(base_opts, overrides)
  end

  def enabled? do
    Keyword.get(config(), :enabled, true)
  end

  defp config do
    Application.get_env(:lumainus, :llm, [])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
