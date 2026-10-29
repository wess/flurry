defmodule Flurry.Release do
  @moduledoc false

  @migrations [
    {1, "initial", Flurry.Migrations.Initial},
    {2, "sources", Flurry.Migrations.Sources},
    {3, "pending", Flurry.Migrations.Pending},
    {4, "settings", Flurry.Migrations.Settings},
    {5, "operations", Flurry.Migrations.Operations},
    {6, "branches", Flurry.Migrations.Branches},
    {7, "gitview", Flurry.Migrations.Gitview},
    {8, "annotations", Flurry.Migrations.Annotations},
    {9, "receipts", Flurry.Migrations.Receipts},
    {10, "organizations", Flurry.Migrations.Organizations},
    {11, "reviewpolicy", Flurry.Migrations.Reviewpolicy},
    {12, "integrations", Flurry.Migrations.Integrations},
    {13, "policies", Flurry.Migrations.Policies},
    {14, "collaboration", Flurry.Migrations.Collaboration},
    {15, "lifecycle", Flurry.Migrations.Lifecycle},
    {16, "lfs", Flurry.Migrations.Lfs},
    {17, "identity", Flurry.Migrations.Identity},
    {19, "automation", Flurry.Migrations.Automation},
    {20, "source_connections", Flurry.Migrations.SourceConnections},
    {22, "instancelimits", Flurry.Migrations.Instancelimits},
    {23, "agents", Flurry.Migrations.Agents},
    {24, "reviewfindings", Flurry.Migrations.Reviewfindings},
    {25, "snippets", Flurry.Migrations.Snippets},
    {26, "passkeys", Flurry.Migrations.Passkeys}
  ]

  def migrate do
    Application.load(:flurry)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Flurry.Repo, fn repo ->
        Enum.each(@migrations, fn {version, file, module} ->
          Code.require_file(Application.app_dir(:flurry, "priv/repo/migrations/#{file}.exs"))
          Ecto.Migrator.up(repo, version, module, log: :info)
        end)
      end)

    :ok
  end
end
