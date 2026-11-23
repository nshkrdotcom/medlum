import Config

# Configure test database
config :medlum, Medlum.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: "medlum_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  ownership_timeout: 300_000,
  migration_lock: nil

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :medlum, MedlumWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "mWh5hLEUFzRa9Jq0pEkjIuwXXfx+UZtg95A3DvZRmTW7ZDvckaO3kzJKF8Y/Tkei",
  server: false

# In test we don't send emails
config :medlum, Medlum.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Suppress noisy InstanceManager "set_stopped" warnings in tests only
config :logger, :console,
  filter_default: :log,
  filters: [
    instance_manager_set_stopped:
      {Logger.Filters, :module_level, {Medlum.Docling.VastAI.InstanceManager, :error}}
  ]

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :medlum, :llm,
  client: Medlum.LLM.MockClient,
  enabled: true

config :medlum, Oban,
  repo: Medlum.Repo,
  testing: :inline,
  queues: false,
  plugins: false

# Keep Docling inline for tests so Bypass expectations on /convert stay valid
# Tests use the standard port layout but with Bypass mocking
config :medlum, :docling,
  queue_mode: :inline,
  # Default mode and active backend
  default_mode: :local,
  active_local_backend: :docker_cpu,
  # All backend URLs (tests mock these via Bypass)
  native_cpu_url: "http://127.0.0.1:8040",
  native_gpu_url: "http://127.0.0.1:8041",
  docker_cpu_url: "http://127.0.0.1:8042",
  docker_gpu_url: "http://127.0.0.1:8043",
  cloud_url: nil,
  # Legacy aliases
  local_url: "http://127.0.0.1:8042",
  remote_url: nil,
  # Timing
  timeout_ms: 1_200_000,
  request_timeout: 1_200_000,
  poll_interval_ms: 1_000,
  # Test options
  prefer_sse: false,
  suppress_logs: true,
  prefer_env_overrides: true,
  # Disable Docker auto-management in tests
  docker_auto_manage: false

config :medlum, :disable_ingestion_health_checker, true

# Higher concurrency for tests to prevent queue delays
config :medlum, :concurrency_gate,
  max_concurrent: 100,
  max_queue: 200
