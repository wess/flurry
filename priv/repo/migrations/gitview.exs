defmodule Flurry.Migrations.Gitview do
  use Ecto.Migration

  def change do
    create table(:gitcommits, primary_key: false) do
      add(:native, :text, primary_key: true)
      add(:repository_id, references(:repositories, type: :uuid), null: false)
      add(:git, :text, null: false)
      add(:raw, :binary, null: false)
      add(:modes, :map, null: false)
    end

    create(index(:gitcommits, [:repository_id, :git]))

    create table(:gitblobs, primary_key: false) do
      add(:native, :text, primary_key: true)
      add(:git, :text, null: false)
    end
  end
end
