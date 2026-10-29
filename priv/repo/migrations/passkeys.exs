defmodule Flurry.Migrations.Passkeys do
  use Ecto.Migration

  def change do
    create table(:passkeys, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:credential_id, :binary, null: false)
      add(:public_key, :binary, null: false)
      add(:name, :text, null: false)
      add(:sign_count, :bigint, null: false, default: 0)
      add(:aaguid, :binary)
      add(:transports, {:array, :text}, null: false, default: [])
      add(:backed_up, :boolean, null: false, default: false)
      add(:last_used_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:passkeys, [:credential_id]))
    create(index(:passkeys, [:user_id, :inserted_at]))
    create(constraint(:passkeys, :nonnegative_passkey_counter, check: "sign_count >= 0"))

    create table(:passkey_challenges, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all))
      add(:kind, :text, null: false)
      add(:bytes, :binary, null: false)
      add(:origin, :text, null: false)
      add(:rp_id, :text, null: false)
      add(:issued_at, :bigint, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:passkey_challenges, [:expires_at]))

    create(
      constraint(:passkey_challenges, :valid_passkey_challenge_kind,
        check: "kind IN ('registration', 'authentication')"
      )
    )
  end
end
