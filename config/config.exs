# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :lumainus, Lumainus.Cldr,
  default_locale: "en",
  locales: ["en", "en-GB", "en-US", "es", "es-US"],
  providers: [Cldr.Number, Cldr.Calendar, Cldr.DateTime],
  gettext: LumainusWeb.Gettext

config :ex_cldr, default_backend: Lumainus.Cldr

config :lumainus, :scopes,
  user: [
    default: true,
    module: Lumainus.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Lumainus.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :lumainus,
  ecto_repos: [Lumainus.Repo],
  generators: [timestamp_type: :utc_datetime]

# Docling Backend Defaults
# ========================
# Default values for Docling Settings database initialization.
# Port assignments (standardized):
#   8040 - native_cpu  (host Python, CPU)
#   8041 - native_gpu  (host Python, GPU)
#   8042 - docker_cpu  (Docker, CPU)
#   8043 - docker_gpu  (Docker, GPU)
#
# User choice: "local" (free) vs "cloud" ($$$)

config :lumainus, :docling,
  default_mode: :local,
  active_local_backend: :docker_cpu,
  native_cpu_url: "http://127.0.0.1:8040",
  native_gpu_url: "http://127.0.0.1:8041",
  docker_cpu_url: "http://127.0.0.1:8042",
  docker_gpu_url: "http://127.0.0.1:8043",
  cloud_url: System.get_env("DOCLING_CLOUD_URL"),
  timeout_ms: 1_200_000,
  poll_interval_ms: 250,
  # Docker auto-management: starts container on Phoenix boot, stops on shutdown
  docker_auto_manage: true,
  docker_service: "docling-cpu",
  # Set true to force container recreation on every Phoenix boot (picks up mounts)
  docker_force_recreate: false

# Vast.ai Auto-Shutdown Configuration
# ====================================
# Automatically destroys idle GPU instances to save money.
# Check runs every X minutes, destroys if idle for Y minutes.
config :lumainus, :vast_ai_auto_shutdown,
  enabled: true,
  # How often to check for idle instances (minutes)
  check_interval_minutes: 5,
  # Destroy instance if no activity for this many minutes
  idle_timeout_minutes: 15,
  # Grace period after provisioning before idle checks can stop instances (minutes)
  post_provisioning_grace_minutes: 3,
  # Pending shutdown window; during this window any activity cancels shutdown (seconds)
  pending_shutdown_seconds: 30

# Conversion System v2 Configuration
# ==================================
# Define which backends are available and how profiles map to them.
#
# Backend types:
#   :local - Docling running on localhost (Docker or native)
#   :cloud - Vast.ai GPU instance (provisioned on demand)
#
# Example configurations:
#
# 1. Default (local + cloud):
#    Uses local Docker for :standard, GPU/cloud for :enhanced
#
# 2. Cloud-only (for production without local GPU):
#    backends: [{:cloud, type: :cloud}],
#    profiles: %{standard: [:cloud], enhanced: [:cloud]}
#
# 3. Local-only (for development):
#    backends: [{:docker_cpu, endpoint: "http://localhost:8042", type: :local}],
#    profiles: %{standard: [:docker_cpu], enhanced: [:docker_cpu]}
#
config :lumainus, :conversion,
  # Available backends (order = fallback preference)
  backends: [
    {:docker_cpu, endpoint: "http://localhost:8042", type: :local},
    {:docker_gpu, endpoint: "http://localhost:8043", type: :local},
    {:local_cpu, endpoint: "http://localhost:8040", type: :local},
    {:local_gpu, endpoint: "http://localhost:8041", type: :local},
    {:cloud, type: :cloud}
  ],
  # Profile to backend mapping (order = preference)
  profiles: %{
    standard: [:docker_cpu, :local_cpu],
    enhanced: [:docker_gpu, :local_gpu, :cloud]
  }

# Ingestion queue configuration
config :lumainus, :ingestion,
  # 20 minutes
  conversion_timeout_ms: 1_200_000,
  max_retries: 3,
  stale_job_threshold_minutes: 60,
  archive_after_days: 7,
  # 50 MB
  max_file_size_bytes: 50_000_000,
  max_pages: 1000

config :lumainus, Oban,
  repo: Lumainus.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 86_400},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", Lumainus.Documents.IngestionCleanupWorker}
     ]}
  ],
  queues: [ingestion: 5, reports: 5, health_checks: 1, maintenance: 1]

config :lumainus, :llm,
  default_provider: "google",
  default_model: "gemini-flash-lite-latest",
  client: Lumainus.LLM,
  enabled: true,
  default_options: [temperature: 0.2, max_output_tokens: 2048]

# Gemini rate limiter configuration (gemini_ex 0.5.0+)
# =====================================================
# Rate limiting is enabled by default in gemini_ex 0.5.0+.
# These settings tune the limiter for conservative production usage
# to avoid 429 quota errors when multiple report sections run concurrently.
#
# Key behaviors:
# - max_concurrency_per_model: Limits concurrent requests per model (default: 4)
# - max_attempts: Number of retry attempts on transient errors (default: 3)
# - base_backoff_ms: Base backoff duration between retries (default: 1000)
# - adaptive_concurrency: Dynamically adjusts based on 429 responses
#
# Structured errors returned:
# - {:error, {:rate_limited, retry_at, details}} - Rate limited with retry info
# - {:error, {:transient_failure, attempts, original_error}} - Transient failure after retries
#
# See: https://hexdocs.pm/gemini_ex/rate_limiting.html
config :gemini_ex, :rate_limiter,
  # Conservative concurrency to avoid 429s when multiple sections run
  max_concurrency_per_model: 2,
  # Retry up to 4 times on transient errors/rate limits
  max_attempts: 4,
  # 1.5 second base backoff (gemini_ex applies exponential + jitter)
  base_backoff_ms: 1500,
  # ±25% jitter to prevent thundering herd
  jitter_factor: 0.25,
  # Enable adaptive mode: reduces concurrency on 429s, increases on success
  adaptive_concurrency: true,
  # Max concurrency the adaptive mode can reach
  adaptive_ceiling: 4,
  # Use prod profile defaults as baseline
  profile: :prod

# Configures the endpoint
config :lumainus, LumainusWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LumainusWeb.ErrorHTML, json: LumainusWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: LumainusWeb.PubSub,
  live_view: [signing_salt: "Od02EEf1"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :lumainus, Lumainus.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  lumainus: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  lumainus: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
