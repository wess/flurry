defmodule Flurry.Migrations.Integrations do
  use Ecto.Migration

  def change do
    create table(:webhooks, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:creator_id, references(:users, type: :uuid), null: false)
      add(:url, :text, null: false)
      add(:secret, :binary, null: false)
      add(:events, {:array, :text}, null: false, default: [])
      add(:enabled, :boolean, null: false, default: true)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:webhooks, [:repository_id, :enabled]))

    create table(:webhook_deliveries, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:webhook_id, references(:webhooks, type: :uuid, on_delete: :delete_all), null: false)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:event, :text, null: false)
      add(:payload, :map, null: false)
      add(:state, :text, null: false, default: "pending")
      add(:attempt, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec, null: false)
      add(:status, :integer)
      add(:response, :text)
      add(:error, :text)
      add(:signature, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:webhook_deliveries, [:state, :next_attempt_at]))
    create(index(:webhook_deliveries, [:webhook_id, :inserted_at]))

    create(
      constraint(:webhook_deliveries, :valid_webhook_delivery_state,
        check: "state IN ('pending', 'delivering', 'delivered', 'dead')"
      )
    )

    create table(:commit_statuses, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:changeset_id, references(:changesets, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:creator_id, references(:users, type: :uuid), null: false)
      add(:context, :text, null: false)
      add(:state, :text, null: false)
      add(:description, :text, null: false, default: "")
      add(:target_url, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:commit_statuses, [:repository_id, :changeset_id, :context]))
    create(index(:commit_statuses, [:repository_id, :changeset_id, :state]))

    create(
      constraint(:commit_statuses, :valid_commit_status_state,
        check: "state IN ('pending', 'success', 'failure', 'error')"
      )
    )
  end
end
