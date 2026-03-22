defmodule BotArmyJobApplications.Repo do
  @moduledoc """
  Ecto repository for the Job Applications bot.

  Migrations are split into two directories:
  - priv/repo/migrations/ — executed by this repo (deployed via Ecto)
  - priv/repo/migrations_portable/ — synced to portable_job_applications mirror (not executed here)
  """
  use Ecto.Repo,
    otp_app: :bot_army_job_applications,
    adapter: Ecto.Adapters.Postgres
end
