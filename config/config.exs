import Config

config :bot_army_job_applications, BotArmyJobApplications.Repo,
  ssl: false

config :logger,
  level: :info

import_config "#{config_env()}.exs"
