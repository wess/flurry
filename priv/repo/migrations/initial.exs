defmodule Flurry.Migrations.Initial do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :text, null: false)
      add(:username, :text, null: false)
      add(:bio, :text, null: false, default: "")
      add(:location, :text, null: false, default: "")
      add(:website, :text, null: false, default: "")
      add(:email, :text, null: false)
      add(:password, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:users, [:email]))
    create(unique_index(:users, [:username]))

    create table(:sessions, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:user_id, references(:users, type: :uuid), null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
    end

    create table(:repositories, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text, null: false, default: "")
      add(:visibility, :text, null: false, default: "private")
      add(:owner_id, references(:users, type: :uuid), null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:repositories, [:owner_id, :name]))

    create(
      constraint(:repositories, :valid_visibility, check: "visibility IN ('public', 'private')")
    )

    create table(:changesets, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:repository_id, references(:repositories, type: :uuid), null: false)
      add(:parent_id, references(:changesets, type: :text))
      add(:source_id, references(:changesets, type: :text))
      add(:author_id, references(:users, type: :uuid), null: false)
      add(:message, :text, null: false)
      add(:changes, :map, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:changesets, [:repository_id, :inserted_at]))
    create(index(:changesets, [:parent_id]))

    create table(:manifests, primary_key: false) do
      add(:changeset_id, references(:changesets, type: :text), primary_key: true)
      add(:root, :text, null: false)
    end

    create table(:refs) do
      add(:repository_id, references(:repositories, type: :uuid), null: false)
      add(:name, :text, null: false)
      add(:head, references(:changesets, type: :text))
    end

    create(unique_index(:refs, [:repository_id, :name]))

    create table(:reviews, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:repository_id, references(:repositories, type: :uuid), null: false)
      add(:changeset_id, references(:changesets, type: :text), null: false)
      add(:status, :text, null: false, default: "open")
      add(:landed_id, references(:changesets, type: :text))
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:reviews, [:changeset_id]))
    create(constraint(:reviews, :valid_status, check: "status IN ('open', 'approved', 'landed')"))

    create table(:comments, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:review_id, references(:reviews, type: :uuid), null: false)
      add(:author_id, references(:users, type: :uuid), null: false)
      add(:body, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    execute(
      """
      CREATE FUNCTION flurry_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'changesets are immutable'; END $$
      """,
      "DROP FUNCTION flurry_immutable()"
    )

    execute(
      """
      CREATE TRIGGER changesets_immutable BEFORE UPDATE OR DELETE ON changesets
      FOR EACH ROW EXECUTE FUNCTION flurry_immutable()
      """,
      "DROP TRIGGER changesets_immutable ON changesets"
    )
  end
end
