defmodule Flurry.Migrations.Snippets do
  use Ecto.Migration

  def change do
    create table(:snippets, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:author_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:slug, :text, null: false)
      add(:title, :text, null: false)
      add(:description, :text, null: false, default: "")
      add(:visibility, :text, null: false, default: "unlisted")
      add(:version, :integer, null: false, default: 1)
      add(:forked_from_id, references(:snippets, type: :uuid, on_delete: :nilify_all))
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:snippets, [:slug]))
    create(index(:snippets, [:visibility, :updated_at]))
    create(index(:snippets, [:author_id, :updated_at]))

    create(
      constraint(:snippets, :valid_snippet_visibility,
        check: "visibility IN ('public', 'unlisted', 'private')"
      )
    )

    create(constraint(:snippets, :positive_snippet_version, check: "version > 0"))

    create table(:snippet_revisions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:snippet_id, references(:snippets, type: :uuid, on_delete: :delete_all), null: false)
      add(:author_id, references(:users, type: :uuid), null: false)
      add(:version, :integer, null: false)
      add(:message, :text, null: false, default: "")
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:snippet_revisions, [:snippet_id, :version]))

    create table(:snippet_files, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:revision_id, references(:snippet_revisions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:name, :text, null: false)
      add(:content, :text, null: false)
      add(:bytes, :integer, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:snippet_files, [:revision_id, :name]))
    create(constraint(:snippet_files, :bounded_snippet_file, check: "bytes BETWEEN 0 AND 262144"))

    create table(:snippet_stars, primary_key: false) do
      add(:snippet_id, references(:snippets, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), primary_key: true)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:snippet_stars, [:user_id, :inserted_at]))

    execute(
      """
      CREATE FUNCTION flurry_snippet_revision_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
          RETURN OLD;
        END IF;

        RAISE EXCEPTION 'snippet revisions are immutable';
      END $$
      """,
      "DROP FUNCTION flurry_snippet_revision_immutable()"
    )

    for table <- ["snippet_revisions", "snippet_files"] do
      execute(
        """
        CREATE TRIGGER #{table}_immutable
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION flurry_snippet_revision_immutable()
        """,
        "DROP TRIGGER #{table}_immutable ON #{table}"
      )
    end
  end
end
