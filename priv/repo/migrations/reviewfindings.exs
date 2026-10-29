defmodule Flurry.Migrations.Reviewfindings do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add(:review_trigger, :text, null: false, default: "manual")
      add(:review_profiles, {:array, :text}, null: false, default: ["correctness", "security"])
      add(:review_status_context, :text)
    end

    create(
      constraint(:repositories, :valid_review_trigger,
        check: "review_trigger IN ('manual', 'review_opened', 'every_revision')"
      )
    )

    create table(:review_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:review_id, references(:reviews, type: :uuid, on_delete: :delete_all), null: false)
      add(:revision_id, references(:changesets, type: :text), null: false)
      add(:creator_id, references(:users, type: :uuid), null: false)
      add(:trigger, :text, null: false)
      add(:profiles, {:array, :text}, null: false, default: [])
      add(:state, :text, null: false, default: "requested")
      add(:summary, :text, null: false, default: "")
      add(:status_context, :text)
      add(:external_id, :text)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:review_runs, [:review_id, :revision_id, :inserted_at]))
    create(index(:review_runs, [:repository_id, :state, :inserted_at]))

    create(
      constraint(:review_runs, :valid_review_run_state,
        check: "state IN ('requested', 'running', 'completed', 'failed', 'cancelled')"
      )
    )

    create(
      constraint(:review_runs, :valid_review_run_trigger,
        check: "trigger IN ('manual', 'review_opened', 'revision')"
      )
    )

    create table(:review_findings, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:review_id, references(:reviews, type: :uuid, on_delete: :delete_all), null: false)
      add(:run_id, references(:review_runs, type: :uuid, on_delete: :delete_all), null: false)
      add(:revision_id, references(:changesets, type: :text), null: false)
      add(:reporter_id, references(:users, type: :uuid), null: false)
      add(:fingerprint, :text, null: false)
      add(:category, :text, null: false)
      add(:severity, :text, null: false)
      add(:classification, :text, null: false, default: "introduced")
      add(:title, :text, null: false)
      add(:body, :text, null: false)
      add(:evidence, :text, null: false, default: "")
      add(:path, :text)
      add(:side, :text)
      add(:line, :integer)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:review_findings, [:run_id, :fingerprint]))
    create(index(:review_findings, [:review_id, :revision_id, :severity]))
    create(index(:review_findings, [:review_id, :fingerprint]))

    create(
      constraint(:review_findings, :valid_review_finding_category,
        check:
          "category IN ('correctness', 'security', 'regression', 'edge_case', 'contract', 'other')"
      )
    )

    create(
      constraint(:review_findings, :valid_review_finding_severity,
        check: "severity IN ('blocker', 'high', 'medium', 'low', 'info')"
      )
    )

    create(
      constraint(:review_findings, :valid_review_finding_classification,
        check: "classification IN ('introduced', 'preexisting')"
      )
    )

    create(
      constraint(:review_findings, :complete_review_finding_anchor,
        check:
          "(path IS NULL AND side IS NULL AND line IS NULL) OR " <>
            "(path IS NOT NULL AND side IN ('before', 'after') AND line > 0)"
      )
    )

    create table(:review_finding_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:finding_id, references(:review_findings, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:actor_id, references(:users, type: :uuid), null: false)
      add(:revision_id, references(:changesets, type: :text), null: false)
      add(:action, :text, null: false)
      add(:note, :text, null: false, default: "")
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:review_finding_events, [:finding_id, :inserted_at]))

    create(
      constraint(:review_finding_events, :valid_review_finding_action,
        check:
          "action IN ('verified', 'resolved', 'dismissed', 'reopened', 'superseded', 'not_reproduced')"
      )
    )

    execute(
      """
      CREATE FUNCTION flurry_review_evidence_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
          RETURN OLD;
        END IF;

        RAISE EXCEPTION 'review evidence is immutable';
      END $$
      """,
      "DROP FUNCTION flurry_review_evidence_immutable()"
    )

    for table <- ["review_findings", "review_finding_events"] do
      execute(
        """
        CREATE TRIGGER #{table}_immutable
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION flurry_review_evidence_immutable()
        """,
        "DROP TRIGGER #{table}_immutable ON #{table}"
      )
    end
  end
end
