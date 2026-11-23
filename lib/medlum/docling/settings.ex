defmodule Medlum.Docling.Settings do
  @moduledoc """
  Persistence layer for Docling runtime configuration.

  Manages the singleton settings record that controls which backend
  is active and how each backend is configured.
  """

  import Ecto.Query, only: [from: 2]

  alias Medlum.Docling.Setting
  alias Medlum.Repo

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

  @doc """
  Update the settings with new attributes.
  """
  def update_settings(attrs) do
    {:ok, setting} = fetch_or_init()

    setting
    |> Setting.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Convenience function to update just the cloud_url.
  Used when setting a Vast.ai instance as the cloud backend.
  """
  def update_cloud_url(url) when is_binary(url) do
    update_settings(%{cloud_url: url})
  end

  @doc """
  Return a changeset for the current settings.
  """
  def change_settings(attrs \\ %{}) do
    {:ok, setting} = fetch_or_init()
    Setting.changeset(setting, attrs)
  end

  @doc """
  Convert a Setting struct to config keywords for use in `Medlum.Docling.config/0`.
  """
  def to_config_keywords(%Setting{} = setting) do
    active_local_backend_atom =
      case setting.active_local_backend do
        nil -> :docker_cpu
        name -> safe_backend_atom(name)
      end

    default_mode_atom =
      case setting.default_mode do
        nil -> :local
        mode -> safe_mode_atom(mode)
      end

    [
      # New fields
      default_mode: default_mode_atom,
      active_local_backend: active_local_backend_atom,
      native_cpu_url: setting.native_cpu_url,
      native_gpu_url: setting.native_gpu_url,
      docker_cpu_url: setting.docker_cpu_url,
      docker_gpu_url: setting.docker_gpu_url,
      cloud_url: setting.cloud_url,
      # Legacy fields (for backward compatibility)
      backend: safe_backend_atom(setting.backend),
      local_url: setting.local_url,
      remote_url: setting.remote_url,
      # Timing
      timeout_ms: setting.timeout_ms,
      poll_interval_ms: setting.poll_interval_ms,
      progress_min_interval_ms: setting.progress_min_interval_ms
    ]
  end

  @doc """
  Get defaults from environment configuration.
  """
  def defaults_from_env do
    env = Application.get_env(:medlum, :docling, [])

    %{
      # New fields
      default_mode: env |> Keyword.get(:default_mode, :local) |> to_string(),
      active_local_backend: env |> Keyword.get(:active_local_backend, :docker_cpu) |> to_string(),
      native_cpu_url: Keyword.get(env, :native_cpu_url, "http://127.0.0.1:8040"),
      native_gpu_url: Keyword.get(env, :native_gpu_url, "http://127.0.0.1:8041"),
      docker_cpu_url: Keyword.get(env, :docker_cpu_url, "http://127.0.0.1:8042"),
      docker_gpu_url: Keyword.get(env, :docker_gpu_url, "http://127.0.0.1:8043"),
      cloud_url: Keyword.get(env, :cloud_url, System.get_env("DOCLING_CLOUD_URL")),
      # Legacy fields
      backend: env |> Keyword.get(:backend, :local) |> to_string(),
      local_url: Keyword.get(env, :local_url, "http://127.0.0.1:8042"),
      remote_url: Keyword.get(env, :remote_url, System.get_env("DOCLING_REMOTE_URL")),
      # Timing
      timeout_ms: Keyword.get(env, :timeout_ms, 1_200_000),
      poll_interval_ms: Keyword.get(env, :poll_interval_ms, 250),
      progress_min_interval_ms: Keyword.get(env, :progress_min_interval_ms, 50),
      # v2 Conversion system profile backends
      v2_profile_backends:
        Keyword.get(env, :v2_profile_backends, %{
          "standard" => ["docker_cpu", "local_cpu"],
          "enhanced" => ["docker_gpu", "local_gpu", "cloud"]
        }),
      singleton: true
    }
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp safe_backend_atom(nil), do: :docker_cpu

  defp safe_backend_atom(name) do
    name
    |> to_string()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> :docker_cpu
  end

  defp safe_mode_atom(nil), do: :local

  defp safe_mode_atom(mode) do
    mode
    |> to_string()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> :local
  end
end
