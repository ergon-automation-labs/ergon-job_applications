defmodule BotArmyJobApplications.Repo.Migrations.AddTenantAndUserId do
  use Ecto.Migration

  def up do
    default_tenant_id = "00000000-0000-0000-0000-000000000001"

    # Add tenant_id and user_id to resumes (idempotent)
    unless Ecto.Migration.column_exists?(:resumes, :tenant_id) do
      alter table(:resumes) do
        add(:tenant_id, :uuid, null: true)
        add(:user_id, :uuid, null: true)
      end

      create(index(:resumes, [:tenant_id]))
      create(index(:resumes, [:user_id]))

      execute(
        "UPDATE resumes SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
      )
    end

    # Add tenant_id and user_id to skills (resume_skills) (idempotent)
    unless Ecto.Migration.column_exists?(:resume_skills, :tenant_id) do
      alter table(:resume_skills) do
        add(:tenant_id, :uuid, null: true)
        add(:user_id, :uuid, null: true)
      end

      create(index(:resume_skills, [:tenant_id]))
      create(index(:resume_skills, [:user_id]))

      execute(
        "UPDATE resume_skills SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
      )
    end

    # Add tenant_id and user_id to roles (resume_roles) (idempotent)
    unless Ecto.Migration.column_exists?(:resume_roles, :tenant_id) do
      alter table(:resume_roles) do
        add(:tenant_id, :uuid, null: true)
        add(:user_id, :uuid, null: true)
      end

      create(index(:resume_roles, [:tenant_id]))
      create(index(:resume_roles, [:user_id]))

      execute(
        "UPDATE resume_roles SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
      )
    end

    # Add tenant_id and user_id to bullets (resume_bullets) (idempotent)
    unless Ecto.Migration.column_exists?(:resume_bullets, :tenant_id) do
      alter table(:resume_bullets) do
        add(:tenant_id, :uuid, null: true)
        add(:user_id, :uuid, null: true)
      end

      create(index(:resume_bullets, [:tenant_id]))
      create(index(:resume_bullets, [:user_id]))

      execute(
        "UPDATE resume_bullets SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
      )
    end

    # Add tenant_id and user_id to listings (idempotent)
    unless Ecto.Migration.column_exists?(:listings, :tenant_id) do
      alter table(:listings) do
        add(:tenant_id, :uuid, null: true)
        add(:user_id, :uuid, null: true)
      end

      create(index(:listings, [:tenant_id]))
      create(index(:listings, [:user_id]))

      execute(
        "UPDATE listings SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
      )
    end

    # Add tenant_id and user_id to applications (idempotent)
    unless Ecto.Migration.column_exists?(:applications, :tenant_id) do
      alter table(:applications) do
        add(:tenant_id, :uuid, null: true)
        add(:user_id, :uuid, null: true)
      end

      create(index(:applications, [:tenant_id]))
      create(index(:applications, [:user_id]))

      execute(
        "UPDATE applications SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
      )
    end
  end

  def down do
    # Drop indexes and columns for resumes
    drop(index(:resumes, [:tenant_id])) if Ecto.Migration.index_exists?(:resumes, [:tenant_id])
    drop(index(:resumes, [:user_id])) if Ecto.Migration.index_exists?(:resumes, [:user_id])

    alter table(:resumes) do
      remove(:tenant_id) if Ecto.Migration.column_exists?(:resumes, :tenant_id)
      remove(:user_id) if Ecto.Migration.column_exists?(:resumes, :user_id)
    end

    # Drop indexes and columns for skills
    drop(index(:resume_skills, [:tenant_id])) if Ecto.Migration.index_exists?(:resume_skills, [:tenant_id])
    drop(index(:resume_skills, [:user_id])) if Ecto.Migration.index_exists?(:resume_skills, [:user_id])

    alter table(:resume_skills) do
      remove(:tenant_id) if Ecto.Migration.column_exists?(:resume_skills, :tenant_id)
      remove(:user_id) if Ecto.Migration.column_exists?(:resume_skills, :user_id)
    end

    # Drop indexes and columns for roles
    drop(index(:resume_roles, [:tenant_id])) if Ecto.Migration.index_exists?(:resume_roles, [:tenant_id])
    drop(index(:resume_roles, [:user_id])) if Ecto.Migration.index_exists?(:resume_roles, [:user_id])

    alter table(:resume_roles) do
      remove(:tenant_id) if Ecto.Migration.column_exists?(:resume_roles, :tenant_id)
      remove(:user_id) if Ecto.Migration.column_exists?(:resume_roles, :user_id)
    end

    # Drop indexes and columns for bullets
    drop(index(:resume_bullets, [:tenant_id])) if Ecto.Migration.index_exists?(:resume_bullets, [:tenant_id])
    drop(index(:resume_bullets, [:user_id])) if Ecto.Migration.index_exists?(:resume_bullets, [:user_id])

    alter table(:resume_bullets) do
      remove(:tenant_id) if Ecto.Migration.column_exists?(:resume_bullets, :tenant_id)
      remove(:user_id) if Ecto.Migration.column_exists?(:resume_bullets, :user_id)
    end

    # Drop indexes and columns for listings
    drop(index(:listings, [:tenant_id])) if Ecto.Migration.index_exists?(:listings, [:tenant_id])
    drop(index(:listings, [:user_id])) if Ecto.Migration.index_exists?(:listings, [:user_id])

    alter table(:listings) do
      remove(:tenant_id) if Ecto.Migration.column_exists?(:listings, :tenant_id)
      remove(:user_id) if Ecto.Migration.column_exists?(:listings, :user_id)
    end

    # Drop indexes and columns for applications
    drop(index(:applications, [:tenant_id])) if Ecto.Migration.index_exists?(:applications, [:tenant_id])
    drop(index(:applications, [:user_id])) if Ecto.Migration.index_exists?(:applications, [:user_id])

    alter table(:applications) do
      remove(:tenant_id) if Ecto.Migration.column_exists?(:applications, :tenant_id)
      remove(:user_id) if Ecto.Migration.column_exists?(:applications, :user_id)
    end
  end
end
