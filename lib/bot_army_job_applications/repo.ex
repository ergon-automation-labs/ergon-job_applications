defmodule BotArmyJobApplications.Repo do
  @moduledoc """
  Ecto repository for the Job Applications bot.
  """
  use Ecto.Repo,
    otp_app: :bot_army_job_applications,
    adapter: Ecto.Adapters.Postgres
end
