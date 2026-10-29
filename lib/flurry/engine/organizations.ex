defmodule Flurry.Engine.Organizations do
  import Ecto.Query
  alias Flurry.{Auth, Error, Repo}

  alias Flurry.Schema.{
    Organization,
    OrganizationMember,
    Repository,
    Team,
    TeamMember,
    TeamRepository,
    User
  }

  @organization_roles ["member", "admin", "owner"]
  @repository_roles ["read", "write", "maintain"]

  def create(user, attrs) do
    name = Auth.text!(attrs["name"], "Organization name", 100)
    slug = slug!(attrs["slug"] || name)

    {:ok, organization} =
      Repo.transaction(fn ->
        organization =
          %Organization{}
          |> Ecto.Changeset.change(id: Ecto.UUID.generate(), name: name, slug: slug)
          |> Ecto.Changeset.unique_constraint(:slug)
          |> insert!("An organization with this slug already exists")

        Repo.insert!(%OrganizationMember{
          organization_id: organization.id,
          user_id: user.id,
          role: "owner"
        })

        organization
      end)

    organization
  end

  def list(user) do
    Repo.all(
      from(o in Organization,
        join: m in OrganizationMember,
        on: m.organization_id == o.id,
        where: m.user_id == ^user.id,
        order_by: o.name,
        select: {o, m.role}
      )
    )
    |> Enum.map(fn {organization, role} -> Map.put(public(organization), :role, role) end)
  end

  def get(user, id, access \\ :read) do
    organization =
      with {:ok, uuid} <- Ecto.UUID.cast(id), do: Repo.get(Organization, uuid)

    if organization && permitted?(organization, user, access),
      do: organization,
      else: Error.fail("Organization not found", 404)
  end

  def role(_organization, nil), do: nil

  def role(organization, user) do
    Repo.one(
      from(m in OrganizationMember,
        where: m.organization_id == ^organization.id and m.user_id == ^user.id,
        select: m.role
      )
    )
  end

  def permitted?(organization, user, access) do
    case {access, role(organization, user)} do
      {:read, role} when role in @organization_roles -> true
      {:manage, role} when role in ["admin", "owner"] -> true
      {:own, "owner"} -> true
      _ -> false
    end
  end

  def member(organization, actor, attrs) do
    manage!(organization, actor)
    username = Auth.text!(attrs["username"], "Username", 80)
    member_role = attrs["role"] || "member"
    unless member_role in @organization_roles, do: Error.fail("Choose a valid organization role")
    user = Repo.get_by(User, username: username) || Error.fail("User not found", 404)

    if user.account_type == "agent" && member_role != "member",
      do: Error.fail("Agent accounts can only be organization members", 409)

    existing = Repo.get_by(OrganizationMember, organization_id: organization.id, user_id: user.id)

    if existing && existing.role == "owner" && member_role != "owner" &&
         owner_count(organization) == 1,
       do: Error.fail("An organization must keep at least one owner", 409)

    member =
      existing || %OrganizationMember{organization_id: organization.id, user_id: user.id}

    member
    |> Ecto.Changeset.change(role: member_role)
    |> Repo.insert_or_update!()

    %{id: user.id, name: user.name, username: user.username, role: member_role}
  end

  def remove_member(organization, actor, user_id) do
    manage!(organization, actor)
    member = Repo.get_by(OrganizationMember, organization_id: organization.id, user_id: user_id)

    if member && member.role == "owner" && owner_count(organization) == 1,
      do: Error.fail("An organization must keep at least one owner", 409)

    if member do
      Repo.delete_all(
        from(m in TeamMember,
          where:
            m.user_id == ^user_id and
              m.team_id in subquery(
                from(t in Team, where: t.organization_id == ^organization.id, select: t.id)
              )
        )
      )

      Repo.delete!(member)
    end

    :ok
  end

  def members(organization) do
    Repo.all(
      from(m in OrganizationMember,
        join: u in User,
        on: u.id == m.user_id,
        where: m.organization_id == ^organization.id,
        order_by: [m.role, u.username],
        select: %{
          id: u.id,
          name: u.name,
          username: u.username,
          account_type: u.account_type,
          role: m.role
        }
      )
    )
  end

  def create_team(organization, actor, attrs) do
    manage!(organization, actor)
    name = Auth.text!(attrs["name"], "Team name", 100)
    slug = slug!(attrs["slug"] || name)

    %Team{}
    |> Ecto.Changeset.change(
      id: Ecto.UUID.generate(),
      organization_id: organization.id,
      name: name,
      slug: slug
    )
    |> Ecto.Changeset.unique_constraint([:organization_id, :slug])
    |> insert!("A team with this slug already exists")
  end

  def teams(organization) do
    Repo.all(from(t in Team, where: t.organization_id == ^organization.id, order_by: t.name))
  end

  def get_team(organization, id) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail("Team not found", 404)

    Repo.one(from(t in Team, where: t.id == ^id and t.organization_id == ^organization.id)) ||
      Error.fail("Team not found", 404)
  end

  def add_team_member(team, actor, %User{} = user, member_role) do
    organization = Repo.get!(Organization, team.organization_id)
    manage_team!(team, organization, actor)

    unless member_role in ["member", "maintainer"],
      do: Error.fail("Choose a valid team role")

    if user.account_type == "agent" && member_role != "member",
      do: Error.fail("Agent accounts cannot maintain teams", 409)

    unless role(organization, user),
      do: Error.fail("Add this user to the organization first", 409)

    record = Repo.get_by(TeamMember, team_id: team.id, user_id: user.id)
    record = record || %TeamMember{team_id: team.id, user_id: user.id}
    record |> Ecto.Changeset.change(role: member_role) |> Repo.insert_or_update!()

    :ok
  end

  def add_team_member(team, actor, %User{} = user),
    do: add_team_member(team, actor, user, "member")

  def add_team_member(team, actor, attrs) when is_map(attrs) do
    username = Auth.text!(attrs["username"], "Username", 80)
    user = Repo.get_by(User, username: username) || Error.fail("User not found", 404)
    add_team_member(team, actor, user, attrs["role"] || "member")
  end

  def remove_team_member(team, actor, user_id) do
    organization = Repo.get!(Organization, team.organization_id)
    manage_team!(team, organization, actor)
    Repo.delete_all(from(m in TeamMember, where: m.team_id == ^team.id and m.user_id == ^user_id))
    :ok
  end

  def grant(team, actor, %Repository{} = repository, repository_role) do
    organization = Repo.get!(Organization, team.organization_id)
    manage!(organization, actor)

    unless repository.organization_id == organization.id,
      do: Error.fail("Teams can only access repositories in their organization", 409)

    unless repository_role in @repository_roles,
      do: Error.fail("Choose a valid repository role")

    record = Repo.get_by(TeamRepository, team_id: team.id, repository_id: repository.id)
    record = record || %TeamRepository{team_id: team.id, repository_id: repository.id}
    record |> Ecto.Changeset.change(role: repository_role) |> Repo.insert_or_update!()
    :ok
  end

  def revoke(team, actor, repository_id) do
    organization = Repo.get!(Organization, team.organization_id)
    manage!(organization, actor)

    Repo.delete_all(
      from(access in TeamRepository,
        where: access.team_id == ^team.id and access.repository_id == ^repository_id
      )
    )

    :ok
  end

  def detail(organization, user \\ nil) do
    Map.merge(public(organization), %{
      role: role(organization, user),
      members: members(organization),
      repositories: organization_repositories(organization),
      teams: Enum.map(teams(organization), &team_detail/1)
    })
  end

  def team_public(team),
    do: %{id: team.id, organization_id: team.organization_id, name: team.name, slug: team.slug}

  defp team_detail(team) do
    Map.merge(team_public(team), %{
      members:
        Repo.all(
          from(m in TeamMember,
            join: u in User,
            on: u.id == m.user_id,
            where: m.team_id == ^team.id,
            order_by: [m.role, u.username],
            select: %{
              id: u.id,
              name: u.name,
              username: u.username,
              account_type: u.account_type,
              role: m.role
            }
          )
        ),
      repositories:
        Repo.all(
          from(a in TeamRepository,
            join: r in Repository,
            on: r.id == a.repository_id,
            where: a.team_id == ^team.id,
            order_by: r.name,
            select: %{id: r.id, name: r.name, role: a.role}
          )
        )
    })
  end

  def repository_role(%Repository{organization_id: nil}, _user), do: nil
  def repository_role(_repository, nil), do: nil

  def repository_role(repository, user) do
    organization_role =
      Repo.one(
        from(m in OrganizationMember,
          where: m.organization_id == ^repository.organization_id and m.user_id == ^user.id,
          select: m.role
        )
      )

    cond do
      organization_role in ["owner", "admin"] -> "owner"
      organization_role == nil -> nil
      true -> team_repository_role(repository, user)
    end
  end

  def accessible_repository_ids(user) do
    managed =
      Repo.all(
        from(r in Repository,
          join: m in OrganizationMember,
          on: m.organization_id == r.organization_id,
          where: m.user_id == ^user.id and m.role in ["owner", "admin"],
          select: r.id
        )
      )

    team =
      Repo.all(
        from(r in Repository,
          join: access in TeamRepository,
          on: access.repository_id == r.id,
          join: member in TeamMember,
          on: member.team_id == access.team_id,
          where: member.user_id == ^user.id,
          select: r.id
        )
      )

    Enum.uniq(managed ++ team)
  end

  def public(organization) do
    %{id: organization.id, name: organization.name, slug: organization.slug}
  end

  defp manage!(organization, actor) do
    unless permitted?(organization, actor, :manage),
      do: Error.fail("Organization administrator access required", 403)
  end

  defp manage_team!(team, organization, actor) do
    maintains =
      Repo.exists?(
        from(m in TeamMember,
          where: m.team_id == ^team.id and m.user_id == ^actor.id and m.role == "maintainer"
        )
      )

    unless permitted?(organization, actor, :manage) or maintains,
      do: Error.fail("Team maintainer access required", 403)
  end

  defp organization_repositories(organization) do
    Repo.all(
      from(r in Repository,
        where: r.organization_id == ^organization.id and is_nil(r.deleted_at),
        order_by: r.name,
        select: %{id: r.id, name: r.name, visibility: r.visibility}
      )
    )
  end

  defp owner_count(organization) do
    Repo.aggregate(
      from(m in OrganizationMember,
        where: m.organization_id == ^organization.id and m.role == "owner"
      ),
      :count
    )
  end

  defp team_repository_role(repository, user) do
    Repo.one(
      from(access in TeamRepository,
        join: member in TeamMember,
        on: member.team_id == access.team_id,
        where: access.repository_id == ^repository.id and member.user_id == ^user.id,
        order_by: [
          desc:
            fragment("CASE ? WHEN 'maintain' THEN 3 WHEN 'write' THEN 2 ELSE 1 END", access.role)
        ],
        limit: 1,
        select: access.role
      )
    )
  end

  defp slug!(value) do
    value = value |> Auth.text!("Slug", 80) |> String.downcase() |> String.replace(~r/\s+/, "-")

    unless Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, value),
      do: Error.fail("Slugs use lowercase letters, numbers, and hyphens")

    value
  end

  defp insert!(changeset, message) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, _} -> Error.fail(message, 409)
    end
  end
end
