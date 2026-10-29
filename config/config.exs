import Config

config :flurry, ecto_repos: [Flurry.Repo]

config :flurry, Flurry.Repo,
  database: "flurry",
  hostname: "localhost",
  pool_size: 10,
  timeout: 120_000

config :flurry,
  store: Path.expand("../data/objects", __DIR__),
  port: 4040,
  host: {127, 0, 0, 1},
  api_rate_limit: 600,
  server: config_env() != :test

if config_env() == :test do
  config :flurry, Flurry.Repo,
    database: "flurrytest",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 20

  config :flurry, store: Path.expand("../data/testobjects", __DIR__)
  config :logger, level: :warning
end
