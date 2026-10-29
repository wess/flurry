defmodule Flurry.Migrations.Settings do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:admin, :boolean, null: false, default: false)
      add(:disabled, :boolean, null: false, default: false)
      add(:private_profile, :boolean, null: false, default: false)
      add(:hide_activity, :boolean, null: false, default: false)
      add(:preferences, :map, null: false, default: %{})
      add(:totp_secret, :binary)
      add(:totp_pending, :binary)
      add(:totp_expires, :utc_datetime_usec)
      add(:totp_last, :bigint)
      add(:recovery_codes, {:array, :text}, null: false, default: [])
    end

    execute(
      "UPDATE users SET admin = true WHERE id = (SELECT id FROM users ORDER BY inserted_at, id LIMIT 1)",
      "UPDATE users SET admin = false"
    )

    alter table(:repositories) do
      add(:archived, :boolean, null: false, default: false)
      add(:deleted_at, :utc_datetime_usec)
      add(:allow_self_approval, :boolean, null: false, default: true)
    end

    alter table(:reviews) do
      add(:approved_by, references(:users, type: :uuid))
    end

    execute(
      "UPDATE reviews r SET approved_by = c.author_id FROM changesets c WHERE r.changeset_id = c.id AND r.status IN ('approved', 'landed')",
      "UPDATE reviews SET approved_by = NULL"
    )

    create table(:members) do
      add(:repository_id, references(:repositories, type: :uuid), null: false)
      add(:user_id, references(:users, type: :uuid), null: false)
      add(:role, :text, null: false)
    end

    create(unique_index(:members, [:repository_id, :user_id]))

    create(
      constraint(:members, :valid_member_role, check: "role IN ('read', 'write', 'maintain')")
    )

    alter table(:sessions) do
      add(:public_id, :uuid, null: false, default: fragment("gen_random_uuid()"))
      add(:label, :text, null: false, default: "Sign-in session")
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create(unique_index(:sessions, [:public_id]))

    create table(:tokens, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid), null: false)
      add(:digest, :text, null: false)
      add(:name, :text, null: false)
      add(:access, :text, null: false)
      add(:repository_id, references(:repositories, type: :uuid))
      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:tokens, [:digest]))
    create(constraint(:tokens, :valid_token_access, check: "access IN ('read', 'write')"))

    create table(:instance, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:name, :text, null: false, default: "Flurry")
      add(:registration, :boolean, null: false, default: true)
      add(:require_signin, :boolean, null: false, default: false)
      add(:allow_public, :boolean, null: false, default: true)
      add(:default_visibility, :text, null: false, default: "private")

      add(:git_hosts, {:array, :text},
        null: false,
        default: ["git.example.com"]
      )
    end

    execute("INSERT INTO instance (id) VALUES (1)", "DELETE FROM instance")

    create table(:audit) do
      add(:actor_id, references(:users, type: :uuid))
      add(:repository_id, references(:repositories, type: :uuid))
      add(:event, :text, null: false)
      add(:details, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:audit, [:actor_id, :inserted_at]))
    create(index(:audit, [:repository_id, :inserted_at]))
  end
end
