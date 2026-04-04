defmodule BotArmyJobApplications.Repo.Migrations.EnforceTenantNotNull do
  use Ecto.Migration

  def up do
    for table <- [:resumes, :resume_roles, :resume_bullets, :skills, :listings, :applications] do
      execute("ALTER TABLE #{table} ALTER COLUMN tenant_id SET NOT NULL")
    end
  end

  def down do
    for table <- [:resumes, :resume_roles, :resume_bullets, :skills, :listings, :applications] do
      execute("ALTER TABLE #{table} ALTER COLUMN tenant_id DROP NOT NULL")
    end
  end
end
