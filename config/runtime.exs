import Config

# Runtime configuration — evaluated when the app starts, not at compile time
# This allows environment variables set by launchd/Salt to be read properly

# Database configuration at runtime
# Priority: BOT_ARMY_JOB_APPLICATIONS_DB_* (set by Salt/Jenkins) > DATABASE_* (from .env for local dev) > defaults
if config_env() != :test do
  alias BotArmyLibraryRuntime.Ecto.RuntimeDbConfig

  db_config =
    RuntimeDbConfig.resolve("BOT_ARMY_JOB_APPLICATIONS",
      database: "ergon_job_applications_dev",
      port: 30006
    )

  config(
    :bot_army_job_applications,
    BotArmyJobApplications.Repo,
    Keyword.merge(
      Keyword.put(
        db_config,
        :pool_size,
        RuntimeDbConfig.pool_size("BOT_ARMY_JOB_APPLICATIONS", 10)
      ),
      ssl: false
    )
  )
end

# Ingestion boards configuration at runtime
# Source: INGESTION_BOARDS_JSON env var (set by Salt pillar via launchd)
# Format: JSON array like [{"source":"greenhouse","board_token":"stripe","company_name":"Stripe"}]
ingestion_boards =
  case BotArmyLibraryRuntime.ConfigLoader.get("INGESTION_BOARDS_JSON") do
    nil ->
      []

    json_str ->
      case Jason.decode(json_str) do
        {:ok, boards} when is_list(boards) -> boards
        _ -> []
      end
  end

config :bot_army_job_applications, :ingestion_boards, ingestion_boards
