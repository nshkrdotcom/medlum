# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

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

config :lumainus, :docling,
  base_url: "http://127.0.0.1:8042",
  request_timeout: 60_000,
  health_cron: "*/5 * * * *"

config :lumainus, Oban,
  repo: Lumainus.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 86_400},
    {Oban.Plugins.Cron, crontab: [{"*/5 * * * *", Lumainus.Docling.HealthCheckWorker}]}
  ],
  queues: [ingestion: 5, reports: 5, health_checks: 1]

config :lumainus, :llm,
  default_provider: "google",
  default_model: "gemini-flash-lite-latest",
  client: Lumainus.LLM,
  enabled: true,
  default_options: [temperature: 0.2, max_output_tokens: 2048]

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
