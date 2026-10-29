defmodule Flurry.RepositoryLifecycleTest do
  use ExUnit.Case, async: false

  alias Flurry.{Auth, Repo}
  alias Flurry.Engine.{Changesets, Refs, Repositories, RepositoryLifecycle, Reviews}
  alias Flurry.Store.{Objects, Tree}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    owner = user("Owner")
    recipient = user("Recipient")

    %{
      owner: owner,
      recipient: recipient,
      repository: Repositories.create(owner, %{"name" => "source"})
    }
  end

  test "duplication copies immutable history, branches and tags without sharing ref state", %{
    owner: owner,
    repository: repository
  } do
    first = submit(repository, owner, nil, "First", "one")
    Reviews.approve(repository, first.review_id, owner)
    first_head = Reviews.land(repository, first.review_id, owner).head
    second = submit(repository, owner, first_head, "Second", "two")
    Reviews.approve(repository, second.review_id, owner)
    second_head = Reviews.land(repository, second.review_id, owner).head
    Refs.tag(repository, owner, %{"name" => "v1", "target" => first_head})

    Repo.insert_all("refs", [
      %{repository_id: Ecto.UUID.dump!(repository.id), name: "stable", head: first_head}
    ])

    copy =
      RepositoryLifecycle.duplicate(repository, owner, %{
        "name" => "copy",
        "description" => "Independent history"
      })

    assert copy.fork_of_id == repository.id
    assert Repositories.head(copy) != second_head
    assert length(Changesets.history(copy, Repositories.head(copy))) == 2
    copied_root = Changesets.root(copy, Repositories.head(copy))
    assert Objects.get(:blob, Tree.entry(copied_root, "readme.md")["hash"]) == "two"

    refs = Refs.list(copy)
    assert Enum.find(refs.branches, &(&1.name == "stable")).head != first_head
    assert Enum.find(refs.tags, &(&1.name == "v1")).target != first_head

    third = submit(repository, owner, second_head, "Third", "three")
    Reviews.approve(repository, third.review_id, owner)
    Reviews.land(repository, third.review_id, owner)
    assert length(Changesets.history(copy, Repositories.head(copy))) == 2
  end

  test "ownership transfer requires recipient acceptance and makes the repository private", %{
    owner: owner,
    recipient: recipient,
    repository: repository
  } do
    repository
    |> Ecto.Changeset.change(visibility: "public")
    |> Repo.update!()

    transfer =
      RepositoryLifecycle.request_transfer(repository, owner, %{
        "username" => recipient.username,
        "password" => "correct horse battery staple"
      })

    assert Enum.any?(RepositoryLifecycle.transfers(recipient), &(&1.id == transfer.id))
    moved = RepositoryLifecycle.accept_transfer(recipient, transfer.id)
    assert moved.owner.id == recipient.id
    assert moved.visibility == "private"
    assert Repositories.get(recipient, repository.id, :manage).id == repository.id
    assert_raise Flurry.Error, fn -> Repositories.get(owner, repository.id) end

    assert_raise Flurry.Error, ~r/no longer pending/, fn ->
      RepositoryLifecycle.accept_transfer(recipient, transfer.id)
    end
  end

  defp submit(repository, user, base, message, content) do
    Changesets.submit(repository, user, %{
      "base" => base,
      "message" => message,
      "files" => [%{"path" => "readme.md", "content" => content}]
    })
  end

  defp user(name) do
    id = Ecto.UUID.generate() |> String.replace("-", "")

    {user, _} =
      Auth.signup(%{
        "name" => name,
        "username" => "u" <> id,
        "email" => id <> "@example.test",
        "password" => "correct horse battery staple"
      })

    user
  end
end
