defmodule BotArmyJobApplications.Application do
  @moduledoc false

  @env Mix.env()

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BotArmyJobApplications.Repo,
      {BotArmyJobApplications.NATS.Consumer, []}
    ]
    |> maybe_add_stores()

    opts = [strategy: :one_for_one, name: BotArmyJobApplications.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_stores(children) do
    if @env == :test do
      children
    else
      [
        # Phase 1: Basic stores
        {BotArmyJobApplications.ResumeStore, []},
        {BotArmyJobApplications.ListingStore, []},
        {BotArmyJobApplications.ApplicationSupervisor, []}
      ] ++ children
    end
  end
end
