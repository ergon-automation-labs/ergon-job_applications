defmodule BotArmyJobApplications.Repo.Migrations.CreateListings do
  use Ecto.Migration

  def change do
    create table(:listings, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :source, :string
      add :source_url, :string
      add :company, :string, null: false
      add :role_title, :string, null: false
      add :jd_text, :text
      add :jd_url, :string
      add :jd_tags, :map
      add :salary_range, :map
      add :coverage_score, :float
      add :status, :string
      add :discovered_at, :naive_datetime
      add :scored_at, :naive_datetime
      add :dedup_hash, :string

      timestamps()
    end

    create index(:listings, [:status])
    create index(:listings, [:dedup_hash], unique: true)
    create index(:listings, [:id])
  end
end
