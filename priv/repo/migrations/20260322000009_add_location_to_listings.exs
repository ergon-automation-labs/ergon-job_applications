defmodule BotArmyJobApplications.Repo.Migrations.AddLocationToListings do
  use Ecto.Migration

  def change do
    alter table(:listings) do
      add :location, :map
    end
  end
end
