defmodule Flurry.Migrations.Owners do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:owner, :boolean, null: false, default: false)
    end
  end
end
