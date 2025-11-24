defmodule Lumainus.Docling do
  @moduledoc """
  Unified API for Docling PDF-to-Markdown conversion with pluggable backends.

  Backends are selected via configuration or per-call overrides. The default
  setup keeps the local CPU Docling service as `:local` while allowing a remote
  GPU-backed service as `:fast` (aliased to the remote HTTP backend).
  """

  import Ecto.Query, warn: false

  alias Lumainus.Docling.HealthCheck
  alias Lumainus.Repo

  @backend_modules %{
    local: Lumainus.Docling.Backends.Local,
    remote: Lumainus.Docling.Backends.Remote,
    fast: Lumainus.Docling.Backends.Remote,
    vast_ai: Lumainus.Docling.Backends.VastAI
  }

  @backend_aliases %{
    :local => :local,
    "local" => :local,
    :remote => :remote,
    "remote" => :remote,
    :fast => :fast,
    "fast" => :fast,
    :vast_ai => :vast_ai,
    "vast_ai" => :vast_ai
  }

  @doc """
  Convert a PDF binary synchronously using the configured (or provided) backend.
  """
  def convert(binary, opts \\ []) when is_binary(binary) do
    backend_module_from_opts(opts).convert(binary, with_timeout(opts))
  end

  @doc """
  Enqueue an asynchronous conversion job.
  """
  def enqueue(binary, opts \\ []) when is_binary(binary) do
    backend_name = backend_name_from_opts(opts)
    backend = backend_module(backend_name)

    with {:ok, job} <- backend.enqueue(binary, with_timeout(opts)) do
      {:ok, ensure_job_backend(job, backend, backend_name)}
    end
  end

  @doc """
  Await completion of a queued job.
  """
  def await(job, opts \\ []) do
    backend_module = job_backend(job, opts[:backend])
    backend_module.await(job, opts)
  end

  @doc """
  Hit the health endpoint for a backend (default: configured backend).
  """
  def health(opts \\ []) do
    backend_name = backend_name_from_opts(opts)

    backend_module(backend_name).health()
  rescue
    e in RuntimeError ->
      {:error, e.message}
  end

  @doc """
  Cancel a running job (best-effort).
  """
  def cancel(job_id, opts \\ []) when is_binary(job_id) do
    backend_name = backend_name_from_opts(opts)
    backend_module(backend_name).cancel(job_id)
  end

  @doc """
  List backend capabilities (if the backend exposes them).
  """
  def capabilities(opts \\ []) do
    backend = backend_module_from_opts(opts)

    if function_exported?(backend, :capabilities, 0) do
      backend.capabilities()
    else
      []
    end
  end

  @doc """
  Resolve the backend module for an optional override.
  """
  def backend(opts \\ []) do
    backend_module_from_opts(opts)
  end

  @doc """
  Resolve a backend module by name or alias.
  """
  def backend_module(name) do
    canonical = normalize_backend_name(name)

    case Map.fetch(@backend_modules, canonical) do
      {:ok, module} -> module
      :error -> raise "Unknown backend: #{inspect(canonical)}"
    end
  end

  @doc """
  Return the backend name for a given set of options or the configured backend.
  """
  def backend_name_from_opts(opts) do
    normalize_backend_name(Keyword.get(opts, :backend, config_backend_name()))
  end

  @doc """
  The configured backend name (normalized).
  """
  def config_backend_name do
    normalize_backend_name(config()[:backend] || :local)
  end

  @doc """
  Default backend for user-facing preferences (local vs fast).
  """
  def user_backend_default do
    normalize_user_backend(config_backend_name())
  end

  @doc """
  Normalize a backend value (atom or string) to a canonical atom.
  """
  def normalize_backend_name(nil), do: :local

  def normalize_backend_name(name) when is_atom(name) do
    Map.get(@backend_aliases, name) ||
      raise ArgumentError, "Unknown backend: #{inspect(name)}"
  end

  def normalize_backend_name(name) when is_binary(name) do
    key = String.downcase(name)

    Map.get(@backend_aliases, key) ||
      raise ArgumentError, "Unknown backend: #{inspect(name)}"
  end

  @doc """
  Normalize to the user-facing backend options (`:local` | `:fast`).
  """
  def normalize_user_backend(name) do
    case normalize_backend_name(name) do
      :fast -> :fast
      :remote -> :fast
      :vast_ai -> :fast
      _ -> :local
    end
  end

  @doc """
  Fetch job status for a given backend/base URL.
  """
  def job_status(job_id, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, base_url(opts))
    Lumainus.Docling.HTTP.job_status(job_id, base_url: base_url)
  end

  def record_health(result) do
    payload =
      case result do
        {:ok, body} ->
          %{
            status: "healthy",
            details: body,
            responded_at: DateTime.utc_now(:second)
          }

        {:error, reason} ->
          %{
            status: "unreachable",
            details: %{error: inspect(reason)}
          }
      end

    record =
      %HealthCheck{}
      |> HealthCheck.changeset(payload)
      |> Repo.insert!()

    {:ok, record}
  end

  def latest_health_check do
    HealthCheck
    |> order_by([h], desc: h.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def base_url(opts \\ []) do
    backend_name = normalize_backend_name(Keyword.get(opts, :backend, config_backend_name()))

    case backend_name do
      :local -> local_url!()
      :fast -> remote_url!()
      :remote -> remote_url!()
      :vast_ai -> remote_url!()
    end
  end

  def timeout do
    config()[:request_timeout] || config()[:timeout_ms] || 1_200_000
  end

  def poll_interval_ms do
    config()[:poll_interval_ms] || 5_000
  end

  def config do
    env_config = Application.get_env(:lumainus, :docling, []) || []

    cond do
      prefer_env_overrides?(env_config) ->
        env_config_with_defaults(env_config)

      true ->
        {:ok, setting} = Lumainus.Docling.Settings.fetch_or_init()
        db_config = Lumainus.Docling.Settings.to_config_keywords(setting)
        env_defaults = env_config_with_defaults(env_config)

        Keyword.merge(env_defaults, db_config, fn _k, env_val, db_val ->
          if is_nil(db_val), do: env_val, else: db_val
        end)
    end
  end

  # Private helpers

  defp with_timeout(opts) do
    opts
    |> Keyword.put_new(:timeout_ms, timeout())
    |> Keyword.put_new(:poll_interval_ms, poll_interval_ms())
  end

  defp job_backend(%{backend: backend_module}, _override) when is_atom(backend_module) do
    backend_module
  end

  defp job_backend(job, override) do
    name =
      cond do
        not is_nil(override) -> normalize_backend_name(override)
        job[:backend_name] -> normalize_backend_name(job[:backend_name])
        job[:backend] -> module_to_backend_name(job[:backend])
        true -> config_backend_name()
      end

    backend_module(name)
  end

  defp module_to_backend_name(module) when is_atom(module) do
    Enum.find_value(@backend_modules, config_backend_name(), fn {name, mod} ->
      if mod == module, do: name
    end)
  end

  defp module_to_backend_name(_module), do: config_backend_name()

  defp ensure_job_backend(job, backend_module, backend_name) do
    job
    |> Map.put_new(:backend, backend_module)
    |> Map.put_new(:backend_name, backend_name)
  end

  defp backend_module_from_opts(opts) do
    opts |> backend_name_from_opts() |> backend_module()
  end

  defp local_url! do
    config()[:local_url] || config()[:base_url] ||
      raise ArgumentError, "set :docling local_url config"
  end

  defp remote_url! do
    config()[:remote_url] || config()[:base_url] ||
      raise ArgumentError, "set :docling remote_url config"
  end

  defp prefer_env_overrides?(env_config) do
    Keyword.get(env_config, :prefer_env_overrides, false) ||
      Application.get_env(:lumainus, :env_overrides_docling, false) ||
      Mix.env() == :test
  end

  defp env_config_with_defaults(env_config) do
    defaults = [
      backend: :local,
      local_url: "http://127.0.0.1:8042",
      remote_url: System.get_env("DOCLING_REMOTE_URL"),
      timeout_ms: 1_200_000,
      poll_interval_ms: 5_000
    ]

    Keyword.merge(defaults, env_config)
  end
end
