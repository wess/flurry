defmodule Flurry.Migrations.Reviewpolicy do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add(:required_approvals, :integer, null: false, default: 1)
    end

    create(
      constraint(:repositories, :valid_required_approvals,
        check: "required_approvals BETWEEN 1 AND 20"
      )
    )

    drop(constraint(:reviews, :valid_status))

    create(
      constraint(:reviews, :valid_status,
        check: "status IN ('open', 'approved', 'changes_requested', 'landed')"
      )
    )

    create table(:review_decisions, primary_key: false) do
      add(:review_id, references(:reviews, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:revision_id, references(:changesets, type: :text), null: false)
      add(:decision, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:review_decisions, :valid_review_decision,
        check: "decision IN ('approve', 'reject')"
      )
    )

    create(index(:review_decisions, [:review_id, :revision_id]))

    execute(
      """
      INSERT INTO review_decisions
        (review_id, user_id, revision_id, decision, inserted_at, updated_at)
      SELECT id, approved_by, changeset_id, 'approve', updated_at, updated_at
      FROM reviews
      WHERE approved_by IS NOT NULL AND status IN ('approved', 'landed')
      """,
      "DELETE FROM review_decisions"
    )

    create table(:review_requests, primary_key: false) do
      add(:review_id, references(:reviews, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:requested_by, references(:users, type: :uuid), null: false)
      add(:revision_id, references(:changesets, type: :text), null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:review_requests, [:review_id, :revision_id]))

    alter table(:comments) do
      add(:revision_id, references(:changesets, type: :text))
      add(:path, :text)
      add(:side, :text)
      add(:line, :integer)
    end

    create(constraint(:comments, :valid_comment_side, check: "side IN ('before', 'after')"))

    create(
      constraint(:comments, :complete_comment_anchor,
        check:
          "(revision_id IS NULL AND path IS NULL AND side IS NULL AND line IS NULL) OR " <>
            "(revision_id IS NOT NULL AND path IS NOT NULL AND side IS NOT NULL AND line > 0)"
      )
    )

    create(index(:comments, [:review_id, :revision_id, :path]))
  end
end
