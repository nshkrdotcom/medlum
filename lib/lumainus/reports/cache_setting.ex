defmodule Lumainus.Reports.CacheSetting do
  @moduledoc """
  Schema for Gemini context cache configuration stored in the database.

  This singleton record controls how the caching layer behaves for report generation:

  - `system_prompt` - The system instruction cached with document context
  - `model` - Which Gemini model to use (must support context caching)
  - `ttl_seconds` - How long caches live before expiring
  - `enabled` - Whether to use caching at all

  ## Supported Models

  Only models that support Gemini context caching can be used. Each has a different
  minimum token requirement:

  | Model                  | Min Tokens |
  |------------------------|------------|
  | gemini-3.0-pro-preview | 2048       |
  | gemini-2.5-pro         | 4096       |
  | gemini-2.5-flash       | 1024       |

  The min token limit is enforced based on the selected model.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          system_prompt: String.t() | nil,
          model: String.t() | nil,
          ttl_seconds: integer() | nil,
          enabled: boolean(),
          singleton: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  # Models that support Gemini context caching with their minimum token requirements
  # This is the single source of truth - no hardcoding elsewhere
  @cache_models %{
    "gemini-3.0-pro-preview" => %{min_tokens: 2048},
    "gemini-2.5-pro" => %{min_tokens: 4096},
    "gemini-2.5-flash" => %{min_tokens: 1024}
  }

  # NOTE: This default system prompt is also defined in Blueprints.default_system_prompt/0
  # The two MUST be kept in sync. This is the canonical system prompt for the application.
  @default_system_prompt """
  You are Lumainus, a clinical documentation system.
  Produce structured markdown with inline citations like [doc-001].
  Return JSON that matches the provided schema exactly.
  """

  schema "cache_settings" do
    field(:system_prompt, :string, default: @default_system_prompt)
    field(:model, :string, default: "gemini-2.5-flash")
    field(:ttl_seconds, :integer, default: 3600)
    field(:enabled, :boolean, default: true)
    field(:singleton, :boolean, default: true)

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :system_prompt,
      :model,
      :ttl_seconds,
      :enabled,
      :singleton
    ])
    |> validate_required([
      :system_prompt,
      :model,
      :ttl_seconds,
      :enabled,
      :singleton
    ])
    |> validate_inclusion(:model, Map.keys(@cache_models),
      message: "must be a cache-compatible model"
    )
    |> validate_number(:ttl_seconds, greater_than: 0, less_than_or_equal_to: 86400)
    |> unique_constraint(:singleton)
  end

  @doc """
  Returns the map of cache-compatible models with their configuration.

  Each model maps to a config with `:min_tokens` key.
  """
  @spec cache_models() :: %{String.t() => %{min_tokens: integer()}}
  def cache_models, do: @cache_models

  @doc """
  Returns list of model names that support caching.
  """
  @spec model_names() :: [String.t()]
  def model_names, do: Map.keys(@cache_models)

  @doc """
  Returns the minimum token count required for the given model.

  Returns 1024 as fallback if model not found.
  """
  @spec min_tokens_for_model(String.t()) :: integer()
  def min_tokens_for_model(model) do
    case Map.get(@cache_models, model) do
      %{min_tokens: min} -> min
      nil -> 1024
    end
  end

  @doc """
  Default system prompt for cache context.

  NOTE: This is also defined in Blueprints.default_system_prompt/0.
  The two MUST be kept in sync.
  """
  def default_system_prompt, do: @default_system_prompt
end
