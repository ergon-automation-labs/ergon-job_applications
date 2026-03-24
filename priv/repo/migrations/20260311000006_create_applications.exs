defmodule BotArmyJobApplications.Repo.Migrations.CreateApplications do
  use Ecto.Migration

  def change do
    create table(:applications, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :listing_id, :string
      add :company, :string, not_null: true
      add :role_title, :string, null: false
      add :jd_url, :string
      add :jd_text, :text
      add :jd_tags, :map
      add :coverage_score, :float
      add :salary_range, :map
      add :strategy, :string
      add :state, :string, null: false
      add :history, {:array, :map}, default: []
      add :pending_signal, :map
      add :next_action, :string
      add :artifacts, :map

      timestamps()
    end

    create index(:applications, [:state])
    create index(:applications, [:listing_id])
    create index(:applications, [:id])
  end
end
