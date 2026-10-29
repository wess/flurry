defmodule Flurry.Migrations.Collaboration do
  use Ecto.Migration

  def change do
    create table(:labels, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:name, :text, null: false)
      add(:color, :text, null: false)
      add(:description, :text, null: false, default: "")
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:labels, [:repository_id, :name]))

    create table(:milestones, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:creator_id, references(:users, type: :uuid), null: false)
      add(:title, :text, null: false)
      add(:description, :text, null: false, default: "")
      add(:state, :text, null: false, default: "open")
      add(:due_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(constraint(:milestones, :valid_milestone_state, check: "state IN ('open', 'closed')"))

    create table(:issues, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:number, :integer, null: false)
      add(:author_id, references(:users, type: :uuid), null: false)
      add(:assignee_id, references(:users, type: :uuid))
      add(:milestone_id, references(:milestones, type: :uuid, on_delete: :nilify_all))
      add(:title, :text, null: false)
      add(:body, :text, null: false, default: "")
      add(:state, :text, null: false, default: "open")
      add(:locked, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:issues, [:repository_id, :number]))
    create(index(:issues, [:repository_id, :state, :updated_at]))
    create(constraint(:issues, :valid_issue_state, check: "state IN ('open', 'closed')"))

    create table(:issue_labels, primary_key: false) do
      add(:issue_id, references(:issues, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:label_id, references(:labels, type: :uuid, on_delete: :delete_all), primary_key: true)
    end

    create table(:issue_comments, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:issue_id, references(:issues, type: :uuid, on_delete: :delete_all), null: false)
      add(:author_id, references(:users, type: :uuid), null: false)
      add(:body, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:issue_comments, [:issue_id, :inserted_at]))

    create table(:releases, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:creator_id, references(:users, type: :uuid), null: false)
      add(:tag, :text, null: false)
      add(:title, :text, null: false)
      add(:notes, :text, null: false, default: "")
      add(:draft, :boolean, null: false, default: false)
      add(:prerelease, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:releases, [:repository_id, :tag]))

    create table(:release_assets, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:release_id, references(:releases, type: :uuid, on_delete: :delete_all), null: false)
      add(:name, :text, null: false)
      add(:content_type, :text, null: false)
      add(:object, :text, null: false)
      add(:bytes, :bigint, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:release_assets, [:release_id, :name]))

    create table(:wiki_pages, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:editor_id, references(:users, type: :uuid), null: false)
      add(:slug, :text, null: false)
      add(:title, :text, null: false)
      add(:body, :text, null: false)
      add(:version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:wiki_pages, [:repository_id, :slug]))

    create table(:repository_topics, primary_key: false) do
      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:topic, :text, primary_key: true)
    end

    create table(:repository_subscriptions, primary_key: false) do
      add(:repository_id, references(:repositories, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:kind, :text, primary_key: true)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      constraint(:repository_subscriptions, :valid_subscription_kind,
        check: "kind IN ('star', 'watch')"
      )
    )
  end
end
