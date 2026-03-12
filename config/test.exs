import Config

# Configure database for tests
config :bot_army_job_applications, BotArmyJobApplications.Repo,
  username: System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_USER", "postgres"),
  password: System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_PASSWORD", "postgres"),
  hostname: System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_PORT", "30004")),
  database: System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_NAME", "bot_army_job_applications_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

config :logger, level: :warning
