defmodule Flurry.Migrations.Agents do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:account_type, :text, null: false, default: "human")
    end

    create(constraint(:users, :valid_account_type, check: "account_type IN ('human', 'agent')"))

    alter table(:teammembers) do
      add(:role, :text, null: false, default: "member")
    end

    create(
      constraint(:teammembers, :valid_team_member_role, check: "role IN ('member', 'maintainer')")
    )

    create table(:agents, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:owner_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:digest, :text, null: false)
      add(:token_prefix, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:last_used_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:agents, [:user_id]))
    create(unique_index(:agents, [:digest]))
    create(index(:agents, [:owner_id, :inserted_at]))
  end
end
