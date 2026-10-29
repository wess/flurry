defmodule Flurry.Engine.Repositories do
  import Ecto.Query
  alias Flurry.{Auth, Error, Repo, Schema.Repository}
  alias Flurry.Engine.{Changesets, RepositoryTemplates}
  alias Flurry.Store.Tree

  def list(user) do
    member_ids =
      Repo.all(
        from(m in "members",
          where: m.user_id == ^Ecto.UUID.dump!(user.id),
          select: type(m.repository_id, Ecto.UUID)
        )
      )

    ids = Enum.uniq(member_ids ++ Flurry.Engine.Organizations.accessible_repository_ids(user))

    Repo.all(
      from(r in Repository,
        where:
          ((r.owner_id == ^user.id and is_nil(r.organization_id)) or r.id in ^ids) and
            is_nil(r.deleted_at),
        order_by: [asc: r.name]
      )
    )
    |> Enum.map(&public/1)
  end

  def explore do
    Repo.all(
      from(r in Repository,
        where: r.visibility == "public" and is_nil(r.deleted_at),
        order_by: [desc: r.inserted_at],
        limit: 100
      )
    )
    |> Enum.map(&public/1)
  end

  def create(user, attrs) do
    name = Auth.text!(attrs["name"], "Repository name", 80)

    unless Regex.match?(~r/\A[a-z0-9][a-z0-9.]*\z/, name),
      do: Error.fail("Repository names use lowercase letters, numbers, and dots")

    description = attrs["description"] || ""

    organization =
      case attrs["organization_id"] do
        nil -> nil
        id -> Flurry.Engine.Organizations.get(user, id, :manage)
      end

    visibility =
      attrs["visibility"] || user.preferences["default_visibility"] ||
        Flurry.Instance.get().default_visibility

    if visibility == "public" and not Flurry.Instance.get().allow_public,
      do: Error.fail("Public repositories are disabled on this instance")

    unless visibility in ["public", "private"],
      do: Error.fail("Choose public or private visibility")

    unless is_binary(description) and String.valid?(description) and
             byte_size(description) <= 500,
           do: Error.fail("Description must be at most 500 bytes")

    {:ok, repository} =
      Repo.transaction(fn ->
        Flurry.Quota.repository!(user)

        changeset =
          Ecto.Changeset.change(%Repository{},
            id: Ecto.UUID.generate(),
            name: name,
            description: description,
            owner_id: user.id,
            organization_id: organization && organization.id,
            visibility: visibility
          )
          |> Ecto.Changeset.unique_constraint(:name,
            name:
              if(organization,
                do: :repositories_organization_name_index,
                else: :repositories_user_name_index
              )
          )

        repository =
          case Repo.insert(changeset) do
            {:ok, repository} -> repository
            {:error, _} -> Error.fail("A repository with this name already exists", 409)
          end

        Repo.insert_all("refs", [
          %{repository_id: Ecto.UUID.dump!(repository.id), name: "main", head: nil}
        ])

        initialize(repository, user, attrs)
        repository
      end)

    repository
  end

  defp initialize(repository, user, attrs) do
    files = RepositoryTemplates.files(attrs, repository, user)

    if files != [] do
      changes = Changesets.prepare(files, Tree.empty(), Flurry.Quota.file_limit(user))
      root = Tree.apply(Tree.empty(), changes) |> Tree.portable!()
      change = Changesets.insert(repository, user.id, nil, nil, "Initial commit", changes, root)

      Repo.update_all(
        from(r in "refs",
          where: r.repository_id == ^Ecto.UUID.dump!(repository.id) and r.name == "main"
        ),
        set: [head: change.id]
      )
    end
  end

  def get(user, id, access \\ :read) do
    user_id = if user, do: user.id, else: nil

    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        repo = Repo.get(Repository, uuid)

        if repo && is_nil(repo.deleted_at) &&
             ((is_nil(repo.organization_id) and repo.owner_id == user_id) or
                permitted?(repo, user, access) or
                (access == :read and repo.visibility == "public")),
           do: repo,
           else: nil

      _ ->
        nil
    end || Error.fail("Repository not found", 404)
  end

  def head(repository) do
    Repo.one(
      from(r in "refs",
        where: r.repository_id == ^Ecto.UUID.dump!(repository.id) and r.name == "main",
        select: r.head
      )
    )
  end

  def role(_repository, nil), do: nil

  def role(repository, user) do
    cond do
      is_nil(repository.organization_id) and repository.owner_id == user.id ->
        "owner"

      true ->
        direct =
          Repo.one(
            from(m in "members",
              where:
                m.repository_id == ^Ecto.UUID.dump!(repository.id) and
                  m.user_id == ^Ecto.UUID.dump!(user.id),
              select: m.role
            )
          )

        organization = Flurry.Engine.Organizations.repository_role(repository, user)
        Enum.max_by([direct, organization], &role_rank/1)
    end
  end

  def permitted?(repository, user, access) do
    role = role(repository, user)

    case access do
      :read -> role in ["read", "write", "maintain", "owner"]
      :write -> role in ["write", "maintain", "owner"]
      :review -> role in ["maintain", "owner"]
      :manage -> role == "owner"
    end
  end

  def writable!(repository) do
    current = Repo.get!(Repository, repository.id)

    if current.archived or current.deleted_at,
      do:
        Error.fail(
          "This repository is archived or removed; restore it before making changes",
          409
        )

    current
  end

  def lock(repository) do
    Repo.one!(
      from(r in "refs",
        where: r.repository_id == ^Ecto.UUID.dump!(repository.id) and r.name == "main",
        lock: "FOR UPDATE",
        select: r.id
      )
    )
  end

  def public(repository) do
    owner =
      if repository.organization_id do
        organization = Repo.get!(Flurry.Schema.Organization, repository.organization_id)

        %{
          id: organization.id,
          name: organization.name,
          username: organization.slug,
          kind: "organization"
        }
      else
        user = Repo.get!(Flurry.Schema.User, repository.owner_id)
        %{id: user.id, name: user.name, username: user.username, kind: "user"}
      end

    %{
      id: repository.id,
      name: repository.name,
      description: repository.description,
      visibility: repository.visibility,
      archived: repository.archived,
      allow_self_approval: repository.allow_self_approval,
      required_approvals: repository.required_approvals,
      required_statuses: repository.required_statuses,
      protected_paths: repository.protected_paths,
      push_allowlist: repository.push_allowlist,
      require_signed_commits: repository.require_signed_commits,
      review_trigger: repository.review_trigger,
      review_profiles: repository.review_profiles,
      review_status_context: repository.review_status_context,
      fork_of_id: repository.fork_of_id,
      owner: owner,
      inserted_at: repository.inserted_at,
      head: head(repository)
    }
  end

  defp role_rank(nil), do: 0
  defp role_rank("read"), do: 1
  defp role_rank("write"), do: 2
  defp role_rank("maintain"), do: 3
  defp role_rank("owner"), do: 4
end
