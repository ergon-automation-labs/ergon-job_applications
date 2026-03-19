import Config

# Runtime configuration — evaluated when the app starts, not at compile time
# This allows environment variables set by launchd/Salt to be read properly

# Database configuration at runtime
# Priority: BOT_ARMY_JOB_APPLICATIONS_DB_* (set by Salt/Jenkins) > DATABASE_* (from .env for local dev) > defaults
config :bot_army_job_applications, BotArmyJobApplications.Repo,
  database: System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_NAME") || System.get_env("DATABASE_NAME") || "ergon_job_applications",
  hostname: System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_HOST") || System.get_env("DATABASE_HOST") || "localhost",
  port: String.to_integer(System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_PORT") || System.get_env("DATABASE_PORT") || "30003"),
  username: System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_USER") || System.get_env("DATABASE_USER") || "postgres",
  password: System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_PASSWORD") || System.get_env("DATABASE_PASSWORD") || "postgres",
  pool_size: 10,
  ssl: false

# Ingestion boards configuration at runtime
# Source: INGESTION_BOARDS_JSON env var (set by Salt pillar via launchd)
# Format: JSON array like [{"source":"greenhouse","board_token":"stripe","company_name":"Stripe"}]
ingestion_boards =
  case System.get_env("INGESTION_BOARDS_JSON") do
    nil -> []
    json_str ->
      case Jason.decode(json_str) do
        {:ok, boards} when is_list(boards) -> boards
        _ -> []
      end
  end

config :bot_army_job_applications, :ingestion_boards, ingestion_boards
