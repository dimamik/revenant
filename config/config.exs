import Config

if config_env() == :test do
  config :revenant, Revenant.TestRepo,
    username: "postgres",
    hostname: "localhost",
    database: "revenant_test",
    pool_size: 5

  config :revenant, validate_state: true

  config :logger, level: :warning
end
