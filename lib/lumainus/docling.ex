defmodule Lumainus.Docling do
  @moduledoc """
  Unified API for Docling PDF-to-Markdown conversion with pluggable backends.

  ## Backend Architecture

  There are 5 backends organized into two user-facing modes:

  ### Local Mode (free)
  - `native_cpu` (port 8040) - Host Python/uvicorn, CPU only
  - `native_gpu` (port 8041) - Host Python/uvicorn, with CUDA
  - `docker_cpu` (port 8042) - Docker container, CPU mode
  - `docker_gpu` (port 8043) - Docker container, GPU mode

  ### Cloud Mode ($$$)
  - `vast_ai` (port 8044) - Vast.ai remote GPU

  Users choose between "local" and "cloud". Admins configure which local backend
  is active via `active_local_backend` setting.

  ## Configuration

  See `config/config.exs` for full configuration options. Key settings:
  - `default_mode` - Default for new users (:local or :cloud)
  - `active_local_backend` - Which local backend to use
  - `*_url` fields - URLs for each backend
  """

  import Ecto.Query, warn: false

  alias Lumainus.Docling.HealthCheck
  alias Lumainus.Repo

  # ---------------------------------------------------------------------------
  # Backend Types
  # ---------------------------------------------------------------------------

  @local_backends [:native_cpu, :native_gpu, :docker_cpu, :docker_gpu]
  @cloud_backends [:vast_ai]
  @all_backends @local_backends ++ @cloud_backends

  @backend_modules %{
    # Local backends (all use the same HTTP module, just different URLs)
    native_cpu: Lumainus.Docling.Backends.Local,
    native_gpu: Lumainus.Docling.Backends.Local,
    docker_cpu: Lumainus.Docling.Backends.Local,
    docker_gpu: Lumainus.Docling.Backends.Local,
    # Cloud backends
    vast_ai: Lumainus.Docling.Backends.VastAI,
    # Legacy aliases
    local: Lumainus.Docling.Backends.Local,
    remote: Lumainus.Docling.Backends.Remote,
    fast: Lumainus.Docling.Backends.Remote
  }

  @backend_aliases %{
    # New backend types
    :native_cpu => :native_cpu,
    "native_cpu" => :native_cpu,
    :native_gpu => :native_gpu,
    "native_gpu" => :native_gpu,
    :docker_cpu => :docker_cpu,
    "docker_cpu" => :docker_cpu,
    :docker_gpu => :docker_gpu,
    "docker_gpu" => :docker_gpu,
    :vast_ai => :vast_ai,
    "vast_ai" => :vast_ai,
    # Legacy aliases
    :local => :docker_cpu,
    "local" => :docker_cpu,
    :remote => :vast_ai,
    "remote" => :vast_ai,
    :fast => :vast_ai,
    "fast" => :vast_ai,
    # User-facing cloud mode
    :cloud => :vast_ai,
    "cloud" => :vast_ai
  }

  # User-facing mode aliases
  @user_mode_aliases %{
    :local => :local,
    "local" => :local,
    :cloud => :cloud,
    "cloud" => :cloud,
    # Legacy
    :fast => :cloud,
    "fast" => :cloud
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

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
  Hit the health endpoint for a backend (default: active local backend).
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

    cond do
      function_exported?(backend, :capabilities, 0) ->
        backend.capabilities()

      function_exported?(Lumainus.Docling.Backends.Local, :capabilities, 0) ->
        Lumainus.Docling.Backends.Local.capabilities()

      true ->
        []
    end
  end

  @doc """
  Resolve the backend module for an optional override.
  """
  def backend(opts \\ []) do
    backend_module_from_opts(opts)
  end

  # ---------------------------------------------------------------------------
  # Backend Resolution
  # ---------------------------------------------------------------------------

  @doc """
  List all local backend types.
  """
  def local_backends, do: @local_backends

  @doc """
  List all cloud backend types.
  """
  def cloud_backends, do: @cloud_backends

  @doc """
  List all backend types.
  """
  def all_backends, do: @all_backends

  @doc """
  Check if a backend type uses GPU.
  """
  def gpu_backend?(backend) do
    backend
    |> normalize_backend_name()
    |> Kernel.in([:native_gpu, :docker_gpu, :vast_ai])
  end

  @doc """
  Check if a backend type is cloud (costs $$$).
  """
  def cloud_backend?(backend) do
    backend
    |> normalize_backend_name()
    |> Kernel.in(@cloud_backends)
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
  Return the backend name for a given set of options or the active backend.
  """
  def backend_name_from_opts(opts) do
    cond do
      # Explicit backend override
      opts[:backend] ->
        normalize_backend_name(opts[:backend])

      # User mode (local/cloud) - resolve to actual backend
      opts[:mode] ->
        resolve_mode_to_backend(opts[:mode])

      # Default to active local backend
      true ->
        active_local_backend()
    end
  end

  @doc """
  The active local backend (from config or DB settings).
  """
  def active_local_backend do
    normalize_backend_name(config()[:active_local_backend] || :docker_cpu)
  end

  @doc """
  The default user mode (:local or :cloud).
  """
  def default_user_mode do
    normalize_user_mode(config()[:default_mode] || :local)
  end

  @doc """
  Normalize a backend value to a canonical atom.
  """
  def normalize_backend_name(nil), do: :docker_cpu

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
  Normalize to user-facing mode (:local | :cloud).
  """
  def normalize_user_mode(mode) do
    Map.get(@user_mode_aliases, mode) ||
      raise ArgumentError, "Unknown mode: #{inspect(mode)}"
  end

  @doc """
  Normalize to user-facing backend preference (:local | :cloud).
  For backward compatibility with existing user.docling_backend field.
  """
  def normalize_user_backend(name) do
    backend = normalize_backend_name(name)

    if backend in @cloud_backends do
      :cloud
    else
      :local
    end
  rescue
    ArgumentError ->
      # Try as mode
      case normalize_user_mode(name) do
        :cloud -> :cloud
        _ -> :local
      end
  end

  @doc """
  Default backend for user-facing preferences (local vs cloud).
  """
  def user_backend_default do
    default_user_mode()
  end

  @doc """
  Resolve user mode to actual backend.
  """
  def resolve_mode_to_backend(mode) do
    case normalize_user_mode(mode) do
      :cloud -> :vast_ai
      :local -> active_local_backend()
    end
  end

  # ---------------------------------------------------------------------------
  # URL Resolution
  # ---------------------------------------------------------------------------

  @doc """
  Get the URL for a specific backend.
  """
  def url_for_backend(backend) do
    backend = normalize_backend_name(backend)
    cfg = config()

    case backend do
      :native_cpu -> cfg[:native_cpu_url]
      :native_gpu -> cfg[:native_gpu_url]
      :docker_cpu -> cfg[:docker_cpu_url]
      :docker_gpu -> cfg[:docker_gpu_url]
      :vast_ai -> cfg[:cloud_url]
      # Legacy fallbacks
      _ -> cfg[:local_url]
    end
  end

  @doc """
  Get the base URL for the given options or active backend.
  """
  def base_url(opts \\ []) do
    backend_name = backend_name_from_opts(opts)
    url = url_for_backend(backend_name)

    unless url do
      raise ArgumentError, "No URL configured for backend: #{backend_name}"
    end

    ensure_https_or_loopback!(url, backend_name, allow_loopback: true)
  end

  @doc """
  Fetch job status for a given backend/base URL.
  """
  def job_status(job_id, opts \\ []) do
    base = Keyword.get(opts, :base_url, base_url(opts))
    Lumainus.Docling.HTTP.job_status(job_id, base_url: base)
  end

  # Legacy aliases for backward compatibility
  def local_url!, do: url_for_backend(active_local_backend()) || raise("No local URL configured")
  def remote_url!, do: url_for_backend(:vast_ai) || raise("No cloud URL configured")

  # ---------------------------------------------------------------------------
  # Health Tracking
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  def timeout do
    config()[:request_timeout] || config()[:timeout_ms] || 1_200_000
  end

  def poll_interval_ms do
    config()[:poll_interval_ms] || 250
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

  # Legacy config_backend_name for backward compatibility
  def config_backend_name, do: active_local_backend()

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

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
        true -> active_local_backend()
      end

    backend_module(name)
  end

  defp module_to_backend_name(module) when is_atom(module) do
    Enum.find_value(@backend_modules, active_local_backend(), fn {name, mod} ->
      if mod == module, do: name
    end)
  end

  defp module_to_backend_name(_module), do: active_local_backend()

  defp ensure_job_backend(job, backend_module, backend_name) do
    job
    |> Map.put_new(:backend, backend_module)
    |> Map.put_new(:backend_name, backend_name)
  end

  defp backend_module_from_opts(opts) do
    opts |> backend_name_from_opts() |> backend_module()
  end

  defp prefer_env_overrides?(env_config) do
    Keyword.get(env_config, :prefer_env_overrides, false) ||
      Application.get_env(:lumainus, :env_overrides_docling, false) ||
      Mix.env() == :test
  end

  defp env_config_with_defaults(env_config) do
    defaults = [
      default_mode: :local,
      active_local_backend: :docker_cpu,
      native_cpu_url: "http://127.0.0.1:8040",
      native_gpu_url: "http://127.0.0.1:8041",
      docker_cpu_url: "http://127.0.0.1:8042",
      docker_gpu_url: "http://127.0.0.1:8043",
      cloud_url: System.get_env("DOCLING_CLOUD_URL"),
      # Legacy
      local_url: "http://127.0.0.1:8042",
      remote_url: System.get_env("DOCLING_CLOUD_URL") || System.get_env("DOCLING_REMOTE_URL"),
      # Timing
      timeout_ms: 1_200_000,
      poll_interval_ms: 250,
      progress_min_interval_ms: 50
    ]

    Keyword.merge(defaults, env_config)
  end

  defp ensure_https_or_loopback!(url, field, opts) do
    allow_loopback = Keyword.get(opts, :allow_loopback, false)

    case URI.parse(url || "") do
      %URI{scheme: "https"} ->
        url

      %URI{scheme: "http", host: host} ->
        if allow_loopback and host in ["localhost", "127.0.0.1"] do
          url
        else
          raise ArgumentError,
                "#{field} must use https (http allowed only for localhost/127.0.0.1)"
        end

      _ ->
        raise ArgumentError, "#{field} must be a valid https URL"
    end
  end
end
