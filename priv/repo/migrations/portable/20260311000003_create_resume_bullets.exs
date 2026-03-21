defmodule BotArmyJobApplications.Repo.Migrations.CreateResumeBullets do
  use Ecto.Migration

  def change do
    create table(:resume_bullets, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :role_id, :string, null: false
      add :text, :string, null: false
      add :alt_phrasings, :map
      add :tags, :map
      add :metrics, :map
      add :strength, :string
      add :sort_order, :integer, default: 0

      timestamps()
    end

    create index(:resume_bullets, [:role_id])
    create index(:resume_bullets, [:id])
  end
end
