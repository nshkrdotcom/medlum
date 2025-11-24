defmodule Lumainus.Docling.Settings do
  @moduledoc """
  Persistence layer for Docling runtime configuration.
  """

  import Ecto.Query, only: [from: 2]

  alias Lumainus.Docling.Setting
  alias Lumainus.Repo

  @doc """
  Returns the active Docling settings, inserting defaults if none exist.
  """
  def fetch_or_init do
    case Repo.one(from(s in Setting, limit: 1)) do
      nil ->
        defaults = defaults_from_env()

        %Setting{}
        |> Setting.changeset(defaults)
        |> Repo.insert(on_conflict: :nothing, conflict_target: :singleton)
        |> case do
          {:ok, setting} -> {:ok, setting}
          {:error, _} -> {:ok, Repo.one!(from(s in Setting, limit: 1))}
        end

      setting ->
        {:ok, setting}
    end
  end

  def update_settings(attrs) do
    {:ok, setting} = fetch_or_init()

    setting
    |> Setting.changeset(attrs)
    |> Repo.update()
  end

  def change_settings(attrs \\ %{}) do
    {:ok, setting} = fetch_or_init()
    Setting.changeset(setting, attrs)
  end

  def to_config_keywords(%Setting{} = setting) do
    backend_atom =
      case setting.backend do
        nil -> :local
        name -> safe_backend_atom(name)
      end

    [
      backend: backend_atom,
      local_url: setting.local_url,
      remote_url: setting.remote_url,
      timeout_ms: setting.timeout_ms,
      poll_interval_ms: setting.poll_interval_ms
    ]
  end

  def defaults_from_env do
    env = Application.get_env(:lumainus, :docling, [])

    %{
      backend: env |> Keyword.get(:backend, :local) |> to_string(),
      local_url: Keyword.get(env, :local_url, "http://127.0.0.1:8042"),
      remote_url: Keyword.get(env, :remote_url, System.get_env("DOCLING_REMOTE_URL")),
      timeout_ms: Keyword.get(env, :timeout_ms, 1_200_000),
      poll_interval_ms: Keyword.get(env, :poll_interval_ms, 5_000),
      singleton: true
    }
  end

  defp safe_backend_atom(name) do
    name
    |> to_string()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> :local
  end
end
