defmodule Flurry.Migrations.Policies do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add(:required_statuses, {:array, :text}, null: false, default: [])
      add(:protected_paths, {:array, :text}, null: false, default: [])
      add(:push_allowlist, {:array, :uuid}, null: false, default: [])
      add(:require_signed_commits, :boolean, null: false, default: false)
    end

    create table(:codeowners, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:pattern, :text, null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:codeowners, [:repository_id, :pattern, :user_id]))

    create table(:signingkeys, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:title, :text, null: false)
      add(:algorithm, :text, null: false)
      add(:public_key, :binary, null: false)
      add(:fingerprint, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:signingkeys, [:user_id, :fingerprint]))
    create(constraint(:signingkeys, :valid_signing_algorithm, check: "algorithm = 'ed25519'"))
    create(constraint(:signingkeys, :valid_signing_key, check: "octet_length(public_key) = 32"))

    create table(:sshkeys, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:title, :text, null: false)
      add(:public_key, :text, null: false)
      add(:fingerprint, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:sshkeys, [:fingerprint]))

    create table(:deploykeys, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:creator_id, references(:users, type: :uuid), null: false)
      add(:title, :text, null: false)
      add(:public_key, :text, null: false)
      add(:fingerprint, :text, null: false)
      add(:write, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:deploykeys, [:repository_id, :fingerprint]))

    create table(:changeset_signatures, primary_key: false) do
      add(:changeset_id, references(:changesets, type: :text, on_delete: :delete_all),
        primary_key: true
      )

      add(:key_id, references(:signingkeys, type: :uuid, on_delete: :restrict), null: false)
      add(:payload_digest, :text, null: false)
      add(:signature, :binary, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:changeset_signatures, [:key_id]))
  end
end
