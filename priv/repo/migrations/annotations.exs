defmodule Flurry.Migrations.Annotations do
  use Ecto.Migration

  def change do
    alter table(:tags) do
      add(:message, :text)
      add(:git, :text)
      add(:raw, :binary)
    end
  end
end
