defmodule BotArmyJobApplications.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :resume_id, :string, null: false
      add :name, :string, null: false
      add :tags, :map
      add :proficiency, :string
      add :years, :integer

      timestamps()
    end

    create index(:skills, [:resume_id])
    create index(:skills, [:id])
  end
end
