defmodule Flurry.Migrations.Identity do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:email_verified_at, :utc_datetime_usec)
    end

    execute("UPDATE users SET email_verified_at = inserted_at")

    create table(:email_tokens, primary_key: false) do
      add(:digest, :text, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:purpose, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:email_tokens, [:user_id, :purpose, :expires_at]))

    create(
      constraint(:email_tokens, :valid_email_token_purpose,
        check: "purpose IN ('verify', 'reset')"
      )
    )

    create table(:mail_deliveries, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:recipient, :text, null: false)
      add(:subject, :text, null: false)
      add(:body, :text, null: false)
      add(:kind, :text, null: false)
      add(:status, :text, null: false, default: "queued")
      add(:attempts, :integer, null: false, default: 0)
      add(:error, :text)
      add(:delivered_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:mail_deliveries, [:status, :inserted_at]))
    create(index(:mail_deliveries, [:user_id, :kind, :inserted_at]))

    create(
      constraint(:mail_deliveries, :valid_mail_status,
        check: "status IN ('queued', 'delivered', 'failed')"
      )
    )

    create table(:notifications, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:actor_id, references(:users, type: :uuid, on_delete: :nilify_all))

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all))

      add(:kind, :text, null: false)
      add(:title, :text, null: false)
      add(:body, :text, null: false, default: "")
      add(:url, :text)
      add(:data, :map, null: false, default: %{})
      add(:read_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:notifications, [:user_id, :read_at, :inserted_at]))
  end
end
