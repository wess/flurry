defmodule Flurry.CollaborationTest do
  use ExUnit.Case, async: false
  alias Flurry.{Auth, Repo}
  alias Flurry.Engine.{Changesets, Collaboration, Refs, Repositories, Reviews}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    id = Ecto.UUID.generate() |> String.replace("-", "")

    {user, _} =
      Auth.signup(%{
        "name" => "Collaboration tester",
        "username" => "u" <> id,
        "email" => id <> "@example.test",
        "password" => "correct horse battery staple"
      })

    %{user: user, repository: Repositories.create(user, %{"name" => "planning"})}
  end

  test "issues combine labels, milestones, assignments, comments and locking", %{
    user: user,
    repository: repository
  } do
    label =
      Collaboration.create_label(repository, %{
        "name" => "priority",
        "color" => "aabbcc",
        "description" => "Needs attention"
      })

    milestone =
      Collaboration.create_milestone(repository, user, %{
        "title" => "First delivery",
        "description" => "Initial scope"
      })

    issue =
      Collaboration.create_issue(repository, user, %{
        "title" => "Document the protocol",
        "body" => "Record the wire behavior.",
        "assignee" => user.username,
        "milestone_id" => milestone.id,
        "label_ids" => [label.id]
      })

    assert issue.number == 1
    assert issue.labels |> hd() |> Map.get(:name) == "priority"

    assert Collaboration.comment(repository, 1, user, %{"body" => "Starting now"}).body ==
             "Starting now"

    assert Collaboration.issue(repository, 1).comments |> length() == 1

    assert Collaboration.update_issue(repository, 1, %{"state" => "closed", "locked" => true}).state ==
             "closed"

    assert_raise Flurry.Error, ~r/locked/, fn ->
      Collaboration.comment(repository, 1, user, %{"body" => "Too late"})
    end
  end

  test "releases retain assets and wiki saves use optimistic versions", %{
    user: user,
    repository: repository
  } do
    submitted =
      Changesets.submit(repository, user, %{
        "base" => nil,
        "message" => "Initial source",
        "files" => [%{"path" => "readme.md", "content" => "hello"}]
      })

    Reviews.approve(repository, submitted.review_id, user)
    head = Reviews.land(repository, submitted.review_id, user).head
    Refs.tag(repository, user, %{"name" => "v1", "target" => head})

    release =
      Collaboration.create_release(repository, user, %{
        "tag" => "v1",
        "title" => "First release",
        "notes" => "Ready to use"
      })

    asset =
      Collaboration.add_asset(repository, release.id, %{
        "name" => "checksums.txt",
        "content_type" => "text/plain",
        "content" => Base.encode64("abc  package\n")
      })

    assert {^asset, "abc  package\n"} = Collaboration.asset(repository, asset.id)

    assert Collaboration.releases(repository)
           |> hd()
           |> Map.get(:assets)
           |> hd()
           |> Map.get(:name) ==
             "checksums.txt"

    page =
      Collaboration.put_wiki(repository, user, "getting-started", %{
        "title" => "Getting started",
        "body" => "Welcome"
      })

    assert page.version == 1

    assert Collaboration.put_wiki(repository, user, "getting-started", %{
             "title" => "Getting started",
             "body" => "Updated",
             "version" => 1
           }).version == 2

    assert_raise Flurry.Error, ~r/changed/, fn ->
      Collaboration.put_wiki(repository, user, "getting-started", %{
        "title" => "Stale",
        "body" => "Stale",
        "version" => 1
      })
    end
  end

  test "topics and repository subscriptions are idempotent", %{
    user: user,
    repository: repository
  } do
    assert Collaboration.put_topics(repository, ["source-control", "elixir", "elixir"]) ==
             ["source-control", "elixir"]

    assert Collaboration.topics(repository) == ["elixir", "source-control"]
    assert Collaboration.subscribe(repository, user, "star", true).count == 1
    assert Collaboration.subscribe(repository, user, "star", true).count == 1
    assert Collaboration.subscribe(repository, user, "star", false).count == 0
  end
end
