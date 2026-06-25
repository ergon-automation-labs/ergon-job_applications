defmodule BotArmyJobApplications.Repo.Migrations.CreateSkillsAndActions do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:skills, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)
      add(:name, :text, null: false)
      add(:slug, :text, null: false)
      add(:markdown_content, :text, null: false)
      add(:version, :integer, null: false, default: 1)
      add(:is_active, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime)
    end

    # Add missing columns if table already exists - use raw SQL to avoid dependency on column_exists?
    execute("""
      DO $$
      BEGIN
        IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name = 'skills' AND column_name = 'slug') THEN
          ALTER TABLE skills ADD COLUMN slug text NOT NULL DEFAULT '';
        END IF;
        IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name = 'skills' AND column_name = 'markdown_content') THEN
          ALTER TABLE skills ADD COLUMN markdown_content text NOT NULL DEFAULT '';
        END IF;
        IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name = 'skills' AND column_name = 'version') THEN
          ALTER TABLE skills ADD COLUMN version integer NOT NULL DEFAULT 1;
        END IF;
        IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name = 'skills' AND column_name = 'is_active') THEN
          ALTER TABLE skills ADD COLUMN is_active boolean NOT NULL DEFAULT true;
        END IF;
      END $$;
    """)

    create_if_not_exists(index(:skills, [:tenant_id, :slug, :version], unique: true))

    create_if_not_exists(
      index(:skills, [:tenant_id, :slug, :is_active],
        unique: true,
        where: "is_active = true"
      )
    )

    create_if_not_exists(index(:skills, [:tenant_id, :is_active], where: "is_active = true"))

    create table(:tenant_actions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:tenant_id, :binary_id, null: false)
      add(:slug, :text, null: false)
      add(:type, :text, null: false)
      add(:config_json, :jsonb, null: false, default: "{}")
      add(:is_active, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime)
    end

    create(index(:tenant_actions, [:tenant_id, :slug], unique: true))

    create(index(:tenant_actions, [:tenant_id, :is_active], where: "is_active = true"))
  end
end
