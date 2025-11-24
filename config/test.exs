import Config

# Configure test database
config :lumainus, Lumainus.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: "lumainus_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :lumainus, LumainusWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "mWh5hLEUFzRa9Jq0pEkjIuwXXfx+UZtg95A3DvZRmTW7ZDvckaO3kzJKF8Y/Tkei",
  server: false

# In test we don't send emails
config :lumainus, Lumainus.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :lumainus, :llm,
  client: Lumainus.LLM.MockClient,
  enabled: true

config :lumainus, Oban,
  repo: Lumainus.Repo,
  testing: :inline,
  queues: false,
  plugins: false

# Keep Docling inline for tests so Bypass expectations on /convert stay valid
config :lumainus, :docling,
  queue_mode: :inline,
  backend: :local,
  local_url: "http://127.0.0.1:8042",
  timeout_ms: 1_200_000,
  request_timeout: 1_200_000,
  poll_interval_ms: 1_000,
  prefer_sse: false,
  suppress_logs: true

config :lumainus, :disable_ingestion_health_checker, true
