defmodule BotArmyJobApplications.Repo.Migrations.AddRecommendationFieldsToListings do
  use Ecto.Migration

  def change do
    alter table(:listings) do
      add :recommendation_score, :float
      add :recommendation_reason, :string
      add :gtd_pushed, :boolean, default: false
    end

    create index(:listings, [:recommendation_score])
  end
end
