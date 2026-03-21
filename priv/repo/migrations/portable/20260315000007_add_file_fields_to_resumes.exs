defmodule BotArmyJobApplications.Repo.Migrations.AddFileFieldsToResumes do
  use Ecto.Migration

  def change do
    alter table(:resumes) do
      add :source_file_path, :string
      add :original_filename, :string
    end
  end
end
