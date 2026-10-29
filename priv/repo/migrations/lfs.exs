defmodule Flurry.Migrations.Lfs do
  use Ecto.Migration

  def change do
    create table(:lfs_objects, primary_key: false) do
      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:oid, :text, primary_key: true)
      add(:size, :bigint, null: false)
      add(:uploaded_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:lfs_objects, [:oid]))
    create(constraint(:lfs_objects, :valid_lfs_size, check: "size >= 0 AND size <= 2147483648"))

    create table(:lfs_locks, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:owner_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:path, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:lfs_locks, [:repository_id, :path]))
    create(index(:lfs_locks, [:repository_id, :inserted_at]))
  end
end
