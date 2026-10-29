defmodule Flurry.Migrations.Pending do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add(:requested_head, references(:changesets, type: :text))
    end
  end
end
