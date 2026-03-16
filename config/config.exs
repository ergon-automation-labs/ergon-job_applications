import Config

# Load .env file for local development/testing
if File.exists?(".env") do
  File.stream!(".env")
  |> Stream.map(&String.trim_trailing/1)
  |> Stream.reject(&String.starts_with?(&1, "#"))
  |> Stream.reject(&(&1 == ""))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] -> System.put_env(key, value)
      _ -> nil
    end
  end)
end

# Ecto repositories for migrations
config :bot_army_job_applications, ecto_repos: [BotArmyJobApplications.Repo]

# Database configuration
# Priority: BOT_ARMY_JOB_APPLICATIONS_DB_* (set by Salt/Jenkins) > DATABASE_* (from .env for local dev) > defaults
config :bot_army_job_applications, BotArmyJobApplications.Repo,
  database: System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_NAME") || System.get_env("DATABASE_NAME", "ergon_job_applications_dev"),
  hostname: System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_HOST") || System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_PORT") || System.get_env("DATABASE_PORT", "30003")),
  username: System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_USER") || System.get_env("DATABASE_USER", "postgres"),
  password: System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_PASSWORD") || System.get_env("DATABASE_PASSWORD", "postgres"),
  pool_size: 10,
  ssl: false

config :logger,
  level: :info

# Job listing ingestion (Phase 2): Greenhouse and Lever boards to fetch.
# Example:
#   config :bot_army_job_applications, :ingestion_boards, [
#     %{source: "greenhouse", board_token: "stripe", company_name: "Stripe"},
#     %{source: "lever", site: "lever", company_name: "Lever"}
#   ]
# Fetch interval: default 6 hours. Set ingestion_interval_ms to 0 to disable periodic fetch (use job.listings.fetch.request to trigger).
config :bot_army_job_applications, :ingestion_boards, []
config :bot_army_job_applications, :ingestion_interval_ms, 6 * 60 * 60 * 1000

# Import environment-specific config
if File.exists?("config/#{Mix.env()}.exs") do
  import_config "#{Mix.env()}.exs"
end
