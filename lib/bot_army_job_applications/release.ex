defmodule BotArmyJobApplications.Release do
  @moduledoc """
  Release tasks for the Job Applications bot.

  Migrations are run via the shared BotArmyRuntime.Ecto.MigrationRunner:

      /path/to/bot_army_job_applications/bin/bot_army_job_applications eval 'BotArmyJobApplications.Release.migrate()'

  Called from Salt during bot deployment, before the bot starts.
  """

  alias BotArmyRuntime.Ecto.MigrationRunner

  @app :bot_army_job_applications

  def migrate do
    MigrationRunner.run(
      repo_module: BotArmyJobApplications.Repo,
      app_module: @app
    )
  end
end
