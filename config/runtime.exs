import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/lumainus_web start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :lumainus, LumainusWeb.Endpoint, server: true
end

docling_env_config =
  Application.get_env(:lumainus, :docling, [])
  |> then(fn docling_config ->
    case System.get_env("DOCLING_REMOTE_URL") do
      nil -> docling_config
      remote_url -> Keyword.merge(docling_config, remote_url: remote_url)
    end
  end)
  |> then(fn docling_config ->
    case System.get_env("DOCLING_URL") do
      nil ->
        docling_config

      docling_url ->
        Keyword.merge(docling_config,
          base_url: docling_url,
          remote_url: Keyword.get(docling_config, :remote_url, docling_url),
          local_url: Keyword.get(docling_config, :local_url, docling_url)
        )
    end
  end)
  |> then(fn docling_config ->
    case System.get_env("DOCLING_DOCKER_AUTO_MANAGE") do
      val when val in ["false", "0", "off", "disable", "disabled", "no"] ->
        Keyword.put(docling_config, :docker_auto_manage, false)

      val when val in ["true", "1", "on", "yes"] ->
        Keyword.put(docling_config, :docker_auto_manage, true)

      _ ->
        docling_config
    end
  end)

docling_env_overrides? =
  System.get_env("DOCLING_URL") || System.get_env("DOCLING_REMOTE_URL") ||
    System.get_env("DOCLING_DOCKER_AUTO_MANAGE")

if docling_env_overrides? do
  config :lumainus, :docling, docling_env_config
end

gemini_key =
  System.get_env("GEMINI_API_KEY") ||
    System.get_env("GOOGLE_API_KEY")

if gemini_key do
  llm_config = Application.get_env(:lumainus, :llm, [])

  config :lumainus, :llm, Keyword.put(llm_config, :api_key, gemini_key)
  config :gemini_ex, api_key: gemini_key
end

# Vast.ai configuration
vast_api_key = System.get_env("VAST_API_KEY")
ghcr_token = System.get_env("GHCR_TOKEN")

if vast_api_key || ghcr_token do
  vast_config = Application.get_env(:lumainus, :vast_ai, [])

  vast_config =
    vast_config
    |> then(fn c -> if vast_api_key, do: Keyword.put(c, :api_key, vast_api_key), else: c end)

  config :lumainus, :vast_ai, vast_config

  # GHCR credentials for private Docker images
  if ghcr_token do
    config :lumainus,
      ghcr_user: System.get_env("GHCR_USER") || "nshkrdotcom",
      ghcr_token: ghcr_token
  end
end

# Cloudflare DNS configuration (for HTTPS provisioning)
# Uses MEDLUMAI_DOT_COM_CLOUDFLARE_* env vars
cloudflare_token = System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_API_TOKEN")
cloudflare_zone_id = System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_ZONE_ID")
cloudflare_account_id = System.get_env("MEDLUMAI_DOT_COM_CLOUDFLARE_ACCOUNT_ID")

if cloudflare_token || cloudflare_zone_id do
  cloudflare_config =
    [domain: "medlumai.com"]
    |> then(fn c ->
      if cloudflare_token, do: Keyword.put(c, :api_token, cloudflare_token), else: c
    end)
    |> then(fn c ->
      if cloudflare_zone_id, do: Keyword.put(c, :zone_id, cloudflare_zone_id), else: c
    end)
    |> then(fn c ->
      if cloudflare_account_id, do: Keyword.put(c, :account_id, cloudflare_account_id), else: c
    end)

  config :lumainus, :cloudflare, cloudflare_config
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :lumainus, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :lumainus, LumainusWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :lumainus, LumainusWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :lumainus, LumainusWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # Use local SMTP server for production
  config :lumainus, Lumainus.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: System.get_env("SMTP_RELAY") || "localhost",
    port: String.to_integer(System.get_env("SMTP_PORT") || "25"),
    username: System.get_env("SMTP_USERNAME") || "",
    password: System.get_env("SMTP_PASSWORD") || "",
    tls: :if_available,
    auth: :never,
    retries: 2

  # Database configuration
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :lumainus, Lumainus.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6
end
