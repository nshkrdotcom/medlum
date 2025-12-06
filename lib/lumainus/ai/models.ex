defmodule Lumainus.AI.Models do
  @moduledoc """
  Use-case based model configuration using gemini_ex atoms.

  Maps application use cases to gemini_ex model atoms. The mapping is
  controlled here; resolution to actual model strings is delegated to
  `Gemini.Config.get_model/1`.

  ## Use Cases

  - `:cache_context` - Model for context caching (must support caching)
  - `:report_section` - Model for generating report sections
  - `:quick_analysis` - Fast model for simple analysis tasks

  ## Usage

      # In code - use the atom
      model = Models.resolve(:cache_context)
      # => "gemini-3-pro-preview"

      # In DB - store "cache_context" string
      # Resolve at runtime: Models.resolve(db_value)
  """

  # Use case -> gemini_ex atom mapping
  # Change ONLY these atoms when you want to switch models for a use case
  # The atoms are defined in gemini_ex's Gemini.Config module
  @use_case_mapping %{
    cache_context: :pro_3_preview,
    report_section: :pro_3_preview,
    quick_analysis: :flash_2_5
  }

  # Min tokens for cache-compatible use cases
  # These are model-dependent but we track them here for validation
  @use_case_min_tokens %{
    # gemini-3-pro-preview min
    cache_context: 2048,
    # same model
    report_section: 2048
  }

  @doc """
  Resolve a use case to its model string via gemini_ex.

  Accepts atom or string (for DB values).

  ## Examples

      iex> Models.resolve(:cache_context)
      "gemini-3-pro-preview"

      iex> Models.resolve("cache_context")
      "gemini-3-pro-preview"
  """
  @spec resolve(atom() | String.t()) :: String.t()
  def resolve(use_case) when is_atom(use_case) do
    case Map.get(@use_case_mapping, use_case) do
      nil -> raise ArgumentError, "Unknown use case: #{use_case}"
      gemini_atom -> Gemini.Config.get_model(gemini_atom)
    end
  end

  def resolve(use_case) when is_binary(use_case) do
    resolve(String.to_existing_atom(use_case))
  rescue
    ArgumentError -> raise ArgumentError, "Unknown use case: #{use_case}"
  end

  @doc """
  Get the gemini_ex atom for a use case (not the resolved string).
  """
  @spec gemini_atom(atom()) :: atom()
  def gemini_atom(use_case) do
    Map.fetch!(@use_case_mapping, use_case)
  end

  @doc """
  List all defined use cases.
  """
  @spec use_cases() :: [atom()]
  def use_cases, do: Map.keys(@use_case_mapping)

  @doc """
  Get min tokens for a cache use case.
  """
  @spec min_tokens_for(atom() | String.t()) :: integer()
  def min_tokens_for(use_case) when is_binary(use_case) do
    min_tokens_for(String.to_existing_atom(use_case))
  end

  def min_tokens_for(use_case) when is_atom(use_case) do
    Map.get(@use_case_min_tokens, use_case, 1024)
  end

  @doc """
  Default use case for context caching.
  """
  @spec default_cache_use_case() :: atom()
  def default_cache_use_case, do: :cache_context
end
