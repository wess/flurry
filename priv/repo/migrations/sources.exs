defmodule Flurry.Migrations.Sources do
  use Ecto.Migration

  def change do
    create table(:sources, primary_key: false) do
      add(:repository_id, references(:repositories, type: :uuid), primary_key: true)
      add(:url, :text, null: false)
      add(:branch, :text)
      add(:status, :text, null: false, default: "ready")
      add(:operation, :text)
      add(:job, :uuid)
      add(:error, :text)
      add(:message, :text)
      add(:commit, :text)
      add(:root, :text)
      add(:modes, :map, null: false, default: %{})
      add(:review_id, references(:reviews, type: :uuid))
      add(:incoming_commit, :text)
      add(:incoming_root, :text)
      add(:incoming_modes, :map)
      add(:push_commit, :text)
      add(:push_root, :text)
      add(:push_modes, :map)
      add(:synced_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sources, [:review_id]))

    create(
      constraint(:sources, :valid_source_status,
        check: "status IN ('ready', 'running', 'failed')"
      )
    )
  end
end
