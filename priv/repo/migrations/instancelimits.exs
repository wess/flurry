defmodule Flurry.Migrations.Instancelimits do
  use Ecto.Migration

  def change do
    alter table(:instance) do
      add(:file_bytes, :bigint, null: false, default: 104_857_600)
      add(:project_storage_bytes, :bigint, null: false, default: 107_374_182_400)
      add(:account_storage_bytes, :bigint, null: false, default: 1_099_511_627_776)
    end

    create(
      constraint(:instance, :valid_storage_limits,
        check: "file_bytes > 0 AND project_storage_bytes >= 0 AND account_storage_bytes >= 0"
      )
    )
  end
end
