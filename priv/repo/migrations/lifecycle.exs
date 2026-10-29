defmodule Flurry.Migrations.Lifecycle do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add(:fork_of_id, references(:repositories, type: :uuid, on_delete: :nilify_all))
    end

    create(index(:repositories, [:fork_of_id]))

    create table(:repository_transfers, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:sender_id, references(:users, type: :uuid), null: false)
      add(:target_user_id, references(:users, type: :uuid, on_delete: :delete_all))

      add(
        :target_organization_id,
        references(:organizations, type: :uuid, on_delete: :delete_all)
      )

      add(:status, :text, null: false, default: "pending")
      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:repository_transfers, [:target_user_id, :status]))
    create(index(:repository_transfers, [:target_organization_id, :status]))

    create(
      unique_index(:repository_transfers, [:repository_id],
        where: "status = 'pending'",
        name: :repository_transfers_pending_index
      )
    )

    create(
      constraint(:repository_transfers, :valid_transfer_target,
        check:
          "(target_user_id IS NOT NULL AND target_organization_id IS NULL) OR " <>
            "(target_user_id IS NULL AND target_organization_id IS NOT NULL)"
      )
    )

    create(
      constraint(:repository_transfers, :valid_transfer_status,
        check: "status IN ('pending', 'accepted', 'cancelled', 'expired')"
      )
    )
  end
end
