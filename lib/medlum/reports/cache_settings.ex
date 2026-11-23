defmodule Medlum.Reports.CacheSettings do
  @moduledoc """
  Persistence layer for Gemini context cache configuration.

  Manages the singleton settings record that controls how document
  context caching works for report generation.

  ## Usage

      # Get current settings (creates defaults if none exist)
      {:ok, settings} = CacheSettings.fetch_or_init()

      # Update settings
      {:ok, updated} = CacheSettings.update_settings(%{model: "gemini-2.5-pro"})

      # Get min tokens for the configured model
      min_tokens = CacheSettings.min_tokens()  # Returns model-specific limit
  """

  import Ecto.Query, only: [from: 2]

  alias Medlum.Reports.CacheSetting
  alias Medlum.Repo

  @doc """
  Returns the active cache settings, inserting defaults if none exist.
  """
  @spec fetch_or_init() :: {:ok, CacheSetting.t()}
  def fetch_or_init do
    case Repo.one(from(s in CacheSetting, limit: 1)) do
      nil ->
        defaults = defaults_from_env()

        %CacheSetting{}
        |> CacheSetting.changeset(defaults)
        |> Repo.insert(on_conflict: :nothing, conflict_target: :singleton)
        |> case do
          {:ok, setting} -> {:ok, setting}
          {:error, _} -> {:ok, Repo.one!(from(s in CacheSetting, limit: 1))}
        end

      setting ->
        {:ok, setting}
    end
  end

  @doc """
  Update the settings with new attributes.
  """
  @spec update_settings(map()) :: {:ok, CacheSetting.t()} | {:error, Ecto.Changeset.t()}
  def update_settings(attrs) do
    {:ok, setting} = fetch_or_init()

    setting
    |> CacheSetting.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Return a changeset for the current settings.
  """
  @spec change_settings(map()) :: Ecto.Changeset.t()
  def change_settings(attrs \\ %{}) do
    {:ok, setting} = fetch_or_init()
    CacheSetting.changeset(setting, attrs)
  end

  @doc """
  Get the configured cache model.

  Returns the model string for use in cache creation.
  Falls back to "gemini-2.5-flash" if settings can't be loaded.
  """
  @spec cache_model() :: String.t()
  def cache_model do
    {:ok, setting} = fetch_or_init()
    setting.model
  end

  @doc """
  Get the configured cache TTL in seconds.
  """
  @spec cache_ttl() :: integer()
  def cache_ttl do
    {:ok, setting} = fetch_or_init()
    setting.ttl_seconds
  end

  @doc """
  Get the configured system prompt for caching.
  """
  @spec system_prompt() :: String.t()
  def system_prompt do
    {:ok, setting} = fetch_or_init()
    setting.system_prompt
  end

  @doc """
  Get the minimum tokens required for caching based on the configured model.

  Different models have different minimum token requirements:
  - gemini-3.0-pro-preview: 2048
  - gemini-2.5-pro: 4096
  - gemini-2.5-flash: 1024
  """
  @spec min_tokens() :: integer()
  def min_tokens do
    model = cache_model()
    CacheSetting.min_tokens_for_model(model)
  end

  @doc """
  Check if caching is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    {:ok, setting} = fetch_or_init()
    setting.enabled
  end

  @doc """
  Get defaults from environment configuration or schema defaults.
  """
  @spec defaults_from_env() :: map()
  def defaults_from_env do
    %{
      system_prompt: CacheSetting.default_system_prompt(),
      model: "gemini-3-pro-preview",
      ttl_seconds: 3600,
      enabled: true,
      singleton: true
    }
  end
end
