defmodule Mix.Tasks.Flurry.Setup do
  use Mix.Task
  @shortdoc "Create the database and apply Flurry migrations"

  def run(_) do
    Mix.Task.run("app.config")

    case Flurry.Repo.__adapter__().storage_up(Flurry.Repo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> Mix.raise(inspect(reason))
    end

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Flurry.Repo, fn repo ->
        Code.require_file("priv/repo/migrations/initial.exs")
        Ecto.Migrator.up(repo, 1, Flurry.Migrations.Initial, log: :info)
        Code.require_file("priv/repo/migrations/sources.exs")
        Ecto.Migrator.up(repo, 2, Flurry.Migrations.Sources, log: :info)
        Code.require_file("priv/repo/migrations/pending.exs")
        Ecto.Migrator.up(repo, 3, Flurry.Migrations.Pending, log: :info)
        Code.require_file("priv/repo/migrations/settings.exs")
        Ecto.Migrator.up(repo, 4, Flurry.Migrations.Settings, log: :info)
        Code.require_file("priv/repo/migrations/operations.exs")
        Ecto.Migrator.up(repo, 5, Flurry.Migrations.Operations, log: :info)
        Code.require_file("priv/repo/migrations/branches.exs")
        Ecto.Migrator.up(repo, 6, Flurry.Migrations.Branches, log: :info)
        Code.require_file("priv/repo/migrations/gitview.exs")
        Ecto.Migrator.up(repo, 7, Flurry.Migrations.Gitview, log: :info)
        Code.require_file("priv/repo/migrations/annotations.exs")
        Ecto.Migrator.up(repo, 8, Flurry.Migrations.Annotations, log: :info)
        Code.require_file("priv/repo/migrations/receipts.exs")
        Ecto.Migrator.up(repo, 9, Flurry.Migrations.Receipts, log: :info)
        Code.require_file("priv/repo/migrations/organizations.exs")
        Ecto.Migrator.up(repo, 10, Flurry.Migrations.Organizations, log: :info)
        Code.require_file("priv/repo/migrations/reviewpolicy.exs")
        Ecto.Migrator.up(repo, 11, Flurry.Migrations.Reviewpolicy, log: :info)
        Code.require_file("priv/repo/migrations/integrations.exs")
        Ecto.Migrator.up(repo, 12, Flurry.Migrations.Integrations, log: :info)
        Code.require_file("priv/repo/migrations/policies.exs")
        Ecto.Migrator.up(repo, 13, Flurry.Migrations.Policies, log: :info)
        Code.require_file("priv/repo/migrations/collaboration.exs")
        Ecto.Migrator.up(repo, 14, Flurry.Migrations.Collaboration, log: :info)
        Code.require_file("priv/repo/migrations/lifecycle.exs")
        Ecto.Migrator.up(repo, 15, Flurry.Migrations.Lifecycle, log: :info)
        Code.require_file("priv/repo/migrations/lfs.exs")
        Ecto.Migrator.up(repo, 16, Flurry.Migrations.Lfs, log: :info)
        Code.require_file("priv/repo/migrations/identity.exs")
        Ecto.Migrator.up(repo, 17, Flurry.Migrations.Identity, log: :info)
        Code.require_file("priv/repo/migrations/automation.exs")
        Ecto.Migrator.up(repo, 19, Flurry.Migrations.Automation, log: :info)
        Code.require_file("priv/repo/migrations/source_connections.exs")
        Ecto.Migrator.up(repo, 20, Flurry.Migrations.SourceConnections, log: :info)
        Code.require_file("priv/repo/migrations/instancelimits.exs")
        Ecto.Migrator.up(repo, 22, Flurry.Migrations.Instancelimits, log: :info)
        Code.require_file("priv/repo/migrations/agents.exs")
        Ecto.Migrator.up(repo, 23, Flurry.Migrations.Agents, log: :info)
        Code.require_file("priv/repo/migrations/reviewfindings.exs")
        Ecto.Migrator.up(repo, 24, Flurry.Migrations.Reviewfindings, log: :info)
        Code.require_file("priv/repo/migrations/snippets.exs")
        Ecto.Migrator.up(repo, 25, Flurry.Migrations.Snippets, log: :info)
        Code.require_file("priv/repo/migrations/passkeys.exs")
        Ecto.Migrator.up(repo, 26, Flurry.Migrations.Passkeys, log: :info)
      end)
  end
end
