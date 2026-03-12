defmodule BotArmyJobApplications.Repo.Migrations.CreateResumes do
  use Ecto.Migration

  def change do
    create table(:resumes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :identity, :map, null: false
      add :metadata, :map

      timestamps()
    end

    create index(:resumes, [:id])
  end
end
