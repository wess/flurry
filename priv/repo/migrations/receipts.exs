defmodule Flurry.Migrations.Receipts do
  use Ecto.Migration

  def change do
    create table(:submission_receipts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:repository_id, references(:repositories, type: :uuid), null: false)
      add(:user_id, references(:users, type: :uuid), null: false)
      add(:key, :text, null: false)
      add(:fingerprint, :text, null: false)
      add(:changeset_id, references(:changesets, type: :text), null: false)
      add(:review_id, references(:reviews, type: :uuid), null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:submission_receipts, [:repository_id, :user_id, :key]))
    create(index(:submission_receipts, [:inserted_at]))
  end
end
