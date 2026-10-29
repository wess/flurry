defmodule Flurry.Migrations.SourceConnections do
  use Ecto.Migration

  def change do
    create table(:source_connections, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:provider, :text, null: false)
      add(:host, :text, null: false)
      add(:account, :text, null: false)
      add(:access_token, :binary, null: false)
      add(:refresh_token, :binary)
      add(:expires_at, :utc_datetime_usec)
      add(:scopes, {:array, :text}, null: false, default: [])
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:source_connections, [:user_id, :provider, :host]))
    create(index(:source_connections, [:user_id, :updated_at]))

    create table(:source_connection_states, primary_key: false) do
      add(:digest, :text, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:provider, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:source_connection_states, [:expires_at]))

    alter table(:sources) do
      add(
        :source_connection_id,
        references(:source_connections, type: :uuid, on_delete: :nilify_all)
      )
    end

    create(index(:sources, [:source_connection_id]))
  end
end
