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

# Database configuration moved to config/runtime.exs to read environment variables at app startup time
# (not at compile time, which is what config.exs does)

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

# GTD Bot integration (personal bot army feature)
# Set to false for portable/standalone distribution
config :bot_army_job_applications, :enable_gtd_integration, true

# Import environment-specific config
if File.exists?("config/#{Mix.env()}.exs") do
  import_config "#{Mix.env()}.exs"
end
