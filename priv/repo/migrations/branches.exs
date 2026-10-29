defmodule Flurry.Migrations.Branches do
  use Ecto.Migration

  def change do
    alter table(:changesets) do
      add(:merge_parent_id, :text)
    end

    alter table(:reviews) do
      add(:series, :boolean, null: false, default: false)
      add(:base_id, :text)
    end

    create table(:tags, primary_key: false) do
      add(:repository_id, references(:repositories, type: :uuid), primary_key: true)
      add(:name, :text, primary_key: true)
      add(:target, :text, null: false)
    end

    create table(:pushes, primary_key: false) do
      add(:repository_id, references(:repositories, type: :uuid), primary_key: true)
      add(:request_id, :uuid, primary_key: true)
      add(:author_id, references(:users, type: :uuid), null: false)
      add(:digest, :text, null: false)
      add(:result, :map, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end
  end
end
