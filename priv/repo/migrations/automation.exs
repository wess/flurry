defmodule Flurry.Migrations.Automation do
  use Ecto.Migration

  def change do
    create table(:automation_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:changeset_id, references(:changesets, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:actor_id, references(:users, type: :uuid), null: false)
      add(:name, :text, null: false)
      add(:version, :text)
      add(:trigger, :text, null: false, default: "api")
      add(:base_revision, :text)
      add(:external_id, :text)
      add(:idempotency_key, :text)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:automation_runs, [:repository_id, :changeset_id]))
    create(index(:automation_runs, [:repository_id, :inserted_at]))

    create table(:evaluation_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:changeset_id, references(:changesets, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:creator_id, references(:users, type: :uuid), null: false)
      add(:context, :text, null: false)
      add(:state, :text, null: false)
      add(:summary, :text, null: false, default: "")
      add(:score, :float)
      add(:pass_count, :integer, null: false, default: 0)
      add(:fail_count, :integer, null: false, default: 0)
      add(:duration_ms, :bigint)
      add(:metrics, :map, null: false, default: %{})
      add(:target_url, :text)
      add(:external_id, :text)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:evaluation_runs, [:repository_id, :changeset_id, :inserted_at]))
    create(index(:evaluation_runs, [:repository_id, :inserted_at]))

    create(
      constraint(:evaluation_runs, :valid_evaluation_state,
        check: "state IN ('success', 'failure', 'error')"
      )
    )

    create(
      constraint(:evaluation_runs, :valid_evaluation_counts,
        check: "pass_count >= 0 AND fail_count >= 0 AND (duration_ms IS NULL OR duration_ms >= 0)"
      )
    )

    execute(
      """
      CREATE FUNCTION flurry_evaluation_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'evaluation runs are immutable'; END $$
      """,
      "DROP FUNCTION flurry_evaluation_immutable()"
    )

    execute(
      """
      CREATE TRIGGER evaluation_runs_immutable
      BEFORE UPDATE OR DELETE ON evaluation_runs
      FOR EACH ROW EXECUTE FUNCTION flurry_evaluation_immutable()
      """,
      "DROP TRIGGER evaluation_runs_immutable ON evaluation_runs"
    )

    execute(
      """
      CREATE TRIGGER automation_runs_immutable
      BEFORE UPDATE OR DELETE ON automation_runs
      FOR EACH ROW EXECUTE FUNCTION flurry_evaluation_immutable()
      """,
      "DROP TRIGGER automation_runs_immutable ON automation_runs"
    )
  end
end
