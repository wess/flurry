defmodule Flurry.OrganizationsTest do
  use ExUnit.Case, async: false
  alias Flurry.{Auth, Repo}
  alias Flurry.Engine.{Organizations, Repositories}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    %{owner: user("Owner"), member: user("Member"), outsider: user("Outsider")}
  end

  test "organizations own repositories without changing personal repository names", %{
    owner: owner
  } do
    personal = Repositories.create(owner, %{"name" => "source"})
    organization = Organizations.create(owner, %{"name" => "Flurry Labs", "slug" => "flurry"})

    repository =
      Repositories.create(owner, %{
        "name" => "source",
        "organization_id" => organization.id
      })

    assert personal.organization_id == nil
    assert repository.organization_id == organization.id

    assert Organizations.list(owner) == [
             Map.put(Organizations.public(organization), :role, "owner")
           ]

    assert Repositories.role(repository, owner) == "owner"

    assert Repositories.public(repository).owner == %{
             id: organization.id,
             name: "Flurry Labs",
             username: "flurry",
             kind: "organization"
           }

    assert_raise Flurry.Error, fn ->
      Repositories.create(owner, %{"name" => "source", "organization_id" => organization.id})
    end
  end

  test "team grants provide the strongest repository permission", %{
    owner: owner,
    member: member
  } do
    organization = Organizations.create(owner, %{"name" => "Workshop"})

    Organizations.member(organization, owner, %{"username" => member.username, "role" => "member"})

    team = Organizations.create_team(organization, owner, %{"name" => "Builders"})
    Organizations.add_team_member(team, owner, member)

    repository =
      Repositories.create(owner, %{"name" => "engine", "organization_id" => organization.id})

    assert_raise Flurry.Error, fn -> Repositories.get(member, repository.id) end

    Organizations.grant(team, owner, repository, "write")
    assert Repositories.get(member, repository.id, :write).id == repository.id
    assert Enum.any?(Repositories.list(member), &(&1.id == repository.id))
    assert_raise Flurry.Error, fn -> Repositories.get(member, repository.id, :review) end

    Organizations.grant(team, owner, repository, "maintain")
    assert Repositories.get(member, repository.id, :review).id == repository.id
  end

  test "organization administration and membership boundaries are enforced", %{
    owner: owner,
    member: member,
    outsider: outsider
  } do
    organization = Organizations.create(owner, %{"name" => "Studio"})
    Organizations.member(organization, owner, %{"username" => member.username, "role" => "admin"})
    team = Organizations.create_team(organization, member, %{"name" => "Reviewers"})

    assert_raise Flurry.Error, fn ->
      Organizations.add_team_member(team, member, outsider)
    end

    assert_raise Flurry.Error, fn ->
      Organizations.member(organization, outsider, %{
        "username" => outsider.username,
        "role" => "member"
      })
    end

    assert_raise Flurry.Error, fn ->
      Organizations.member(organization, owner, %{
        "username" => owner.username,
        "role" => "admin"
      })
    end
  end

  test "removing an organization member also removes team access", %{
    owner: owner,
    member: member
  } do
    organization = Organizations.create(owner, %{"name" => "Collective"})
    Organizations.member(organization, owner, %{"username" => member.username})
    team = Organizations.create_team(organization, owner, %{"name" => "Core"})
    Organizations.add_team_member(team, owner, member)

    repository =
      Repositories.create(owner, %{"name" => "product", "organization_id" => organization.id})

    Organizations.grant(team, owner, repository, "read")
    assert Repositories.get(member, repository.id)
    Organizations.remove_member(organization, owner, member.id)
    assert_raise Flurry.Error, fn -> Repositories.get(member, repository.id) end
  end

  test "team maintainers manage membership without administering repository grants", %{
    owner: owner,
    member: maintainer,
    outsider: teammate
  } do
    organization = Organizations.create(owner, %{"name" => "Maintained team"})
    Organizations.member(organization, owner, %{"username" => maintainer.username})
    Organizations.member(organization, owner, %{"username" => teammate.username})
    team = Organizations.create_team(organization, owner, %{"name" => "Operators"})
    Organizations.add_team_member(team, owner, maintainer, "maintainer")
    Organizations.add_team_member(team, maintainer, teammate, "member")

    detail = Organizations.detail(organization, maintainer)
    assert detail.role == "member"
    assert hd(detail.teams).members |> Enum.any?(&(&1.username == teammate.username))

    repository =
      Repositories.create(owner, %{"name" => "service", "organization_id" => organization.id})

    assert_raise Flurry.Error, fn ->
      Organizations.grant(team, maintainer, repository, "write")
    end

    Organizations.remove_team_member(team, maintainer, teammate.id)

    refute Organizations.detail(organization).teams
           |> hd()
           |> Map.get(:members)
           |> Enum.any?(&(&1.id == teammate.id))
  end

  defp user(label) do
    id = String.replace(Ecto.UUID.generate(), "-", "")

    {user, _} =
      Auth.signup(%{
        "name" => label,
        "username" => "u" <> id,
        "email" => id <> "@example.test",
        "password" => "correct horse battery staple"
      })

    user
  end
end
