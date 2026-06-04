defmodule BotArmyJobApplications.Repo.Migrations.CreateHeartbeats do
  use Ecto.Migration

  def change do
<<<<<<< HEAD
    create_if_not_exists table(:heartbeats, primary_key: false) do
=======
    create_if_not_exists table(:heartbeats, primary_key: false) do
>>>>>>> eec3bc5 (feat: Add heartbeats table migration for status persistence)
      add :id, :uuid, primary_key: true
      add :bot_id, :string, null: false
      add :service, :string, null: false
      add :tenant_id, :uuid, null: false
      add :source, :string
      add :status, :string, null: false
      add :uptime_seconds, :integer
      add :last_event_age_ms, :integer
      add :sequence, :integer
      add :payload, :jsonb
      add :recorded_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

<<<<<<< HEAD
    create unique_index(:heartbeats, [:service, :tenant_id])
    create index(:heartbeats, [:bot_id])
    create index(:heartbeats, [:tenant_id])
    create index(:heartbeats, [:service])
=======
    create_if_not_exists unique_index(:heartbeats, [:service, :tenant_id])
    create_if_not_exists index(:heartbeats, [:bot_id])
    create_if_not_exists index(:heartbeats, [:tenant_id])
    create_if_not_exists index(:heartbeats, [:service])
>>>>>>> eec3bc5 (feat: Add heartbeats table migration for status persistence)
  end
end
