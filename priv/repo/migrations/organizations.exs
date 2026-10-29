defmodule Flurry.Migrations.Organizations do
  use Ecto.Migration

  def change do
    create table(:organizations, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :text, null: false)
      add(:slug, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:organizations, [:slug]))

    create table(:organizationmembers) do
      add(:organization_id, references(:organizations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:role, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:organizationmembers, [:organization_id, :user_id]))

    create(
      constraint(:organizationmembers, :valid_organization_role,
        check: "role IN ('member', 'admin', 'owner')"
      )
    )

    create table(:teams, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organization_id, references(:organizations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:name, :text, null: false)
      add(:slug, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:teams, [:organization_id, :slug]))

    create table(:teammembers) do
      add(:team_id, references(:teams, type: :uuid, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:teammembers, [:team_id, :user_id]))

    alter table(:repositories) do
      add(:organization_id, references(:organizations, type: :uuid, on_delete: :nilify_all))
    end

    drop(unique_index(:repositories, [:owner_id, :name]))

    create(
      unique_index(:repositories, [:owner_id, :name],
        where: "organization_id IS NULL",
        name: :repositories_user_name_index
      )
    )

    create(
      unique_index(:repositories, [:organization_id, :name],
        where: "organization_id IS NOT NULL",
        name: :repositories_organization_name_index
      )
    )

    create(index(:repositories, [:organization_id]))

    create table(:teamrepositories) do
      add(:team_id, references(:teams, type: :uuid, on_delete: :delete_all), null: false)

      add(
        :repository_id,
        references(:repositories, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:role, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:teamrepositories, [:team_id, :repository_id]))
    create(index(:teamrepositories, [:repository_id]))

    create(
      constraint(:teamrepositories, :valid_team_repository_role,
        check: "role IN ('read', 'write', 'maintain')"
      )
    )
  end
end
