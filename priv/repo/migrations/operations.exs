defmodule Flurry.Migrations.Operations do
  use Ecto.Migration

  def change do
    alter table(:instance) do
      add(:owner_id, references(:users, type: :uuid))
    end

    execute(
      "UPDATE instance SET owner_id = (SELECT id FROM users ORDER BY inserted_at, id LIMIT 1) WHERE id = 1",
      "UPDATE instance SET owner_id = NULL"
    )

    alter table(:users) do
      add(:storage_migrated, :boolean, null: false, default: false)
    end

    create table(:repositoryobjects, primary_key: false) do
      add(:repository_id, references(:repositories, type: :uuid), primary_key: true)
      add(:hash, :text, primary_key: true)
      add(:bytes, :bigint, null: false)
    end
  end
end
