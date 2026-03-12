# Start the Ecto sandbox for all tests
Ecto.Adapters.SQL.Sandbox.mode(BotArmyJobApplications.Repo, :manual)

ExUnit.start()
