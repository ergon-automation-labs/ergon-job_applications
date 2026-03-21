defmodule BotArmyJobApplications.Repo.Migrations.CreateResumeRoles do
  use Ecto.Migration

  def change do
    create table(:resume_roles, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :resume_id, :string, null: false
      add :title, :string, null: false
      add :company, :string, null: false
      add :start_date, :date
      add :end_date, :date
      add :framing_profiles, :map
      add :sort_order, :integer, default: 0

      timestamps()
    end

    create index(:resume_roles, [:resume_id])
    create index(:resume_roles, [:id])
  end
end
