defmodule Flurry.BranchesTest do
  use ExUnit.Case, async: false
  alias Flurry.{Auth, Repo, Store.Tree}
  alias Flurry.Engine.{Repositories, Transfers, Changesets, Reviews, Refs, Graph}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    id = String.replace(Ecto.UUID.generate(), "-", "")

    {user, _} =
      Auth.signup(%{
        "username" => "f" <> id,
        "email" => id <> "@example.test",
        "name" => "CLI tester",
        "password" => "a long fixture password"
      })

    %{user: user, repository: Repositories.create(user, %{"name" => "branches"})}
  end

  defp commit(parent, path, content, merge \\ nil) do
    %{
      "id" => Ecto.UUID.generate(),
      "parent" => parent,
      "merge_parent" => merge,
      "message" => "Commit #{path}",
      "files" => [%{"path" => path, "content" => content}]
    }
  end

  defp push(repository, user, branch, expected, commits) do
    tip = List.last(commits)["id"]

    Transfers.push(repository, user, %{
      "request_id" => Ecto.UUID.generate(),
      "branch" => branch,
      "expected" => expected,
      "head" => tip,
      "commits" => commits
    })
  end

  test "multi-commit main pushes are reviewable, preserve history, and retry without duplicates",
       %{user: user, repository: repo} do
    first = commit(nil, "a", "a")
    second = commit(first["id"], "b", "b")

    attrs = %{
      "request_id" => Ecto.UUID.generate(),
      "branch" => "main",
      "expected" => nil,
      "head" => second["id"],
      "commits" => [first, second]
    }

    result = Transfers.push(repo, user, attrs)
    assert result == Transfers.push(repo, user, attrs)
    assert Transfers.receipt(repo, user, attrs["request_id"]).accepted
    refute Transfers.receipt(repo, user, Ecto.UUID.generate()).accepted
    assert Repositories.head(repo) == nil
    detail = Reviews.get(repo, result["review_id"]) |> then(&Reviews.detail(repo, &1))
    assert Enum.sort(Enum.map(detail.diff, & &1.path)) == ["a", "b"]
    Reviews.approve(repo, result["review_id"], user)
    assert Reviews.land(repo, result["review_id"], user).head == result["head"]
    assert Changesets.get(repo, result["head"]).parent_id == result["commits"][first["id"]]

    assert_raise Flurry.Error, fn ->
      Transfers.push(repo, user, Map.put(attrs, "branch", "other"))
    end
  end

  test "topic pushes retain two merge parents and reject stale or non-fast-forward pushes", %{
    user: user,
    repository: repo
  } do
    base = push(repo, user, "feature", nil, [commit(nil, "a", "a")])["head"]
    left = push(repo, user, "left", nil, [commit(base, "left", "left")])["head"]
    right = push(repo, user, "right", nil, [commit(base, "right", "right")])["head"]
    merged = push(repo, user, "left", left, [commit(left, "right", "right", right)])["head"]
    assert Changesets.get(repo, merged).merge_parent_id == right
    assert Graph.ancestor?(repo, right, merged)
    assert Graph.merge_base(repo, left, right) == base
    assert Graph.merge_base(repo, merged, right) == right
    assert Refs.head(repo, "left") == merged

    assert_raise Flurry.Error, fn ->
      push(repo, user, "left", left, [commit(left, "stale", "stale")])
    end

    assert_raise Flurry.Error, fn ->
      push(repo, user, "left", merged, [commit(base, "reset", "reset")])
    end

    assert Tree.files(Changesets.root(repo, merged)) |> Map.keys() |> Enum.sort() == [
             "a",
             "left",
             "right"
           ]
  end

  test "tags are immutable and Git views are deterministic and reject forged commit metadata", %{
    user: user,
    repository: repo
  } do
    first = push(repo, user, "feature", nil, [commit(nil, "readme.md", "hello\n")])["head"]
    tag = %{"name" => "v1.0", "target" => first}
    assert Refs.tag(repo, user, tag) == Refs.tag(repo, user, tag)
    second = push(repo, user, "feature", first, [commit(first, "more", "more")])["head"]
    assert_raise Flurry.Error, fn -> Refs.tag(repo, user, Map.put(tag, "target", second)) end
    a = Flurry.Git.View.public(repo, second)
    b = Flurry.Git.View.public(repo, second)
    assert a == b
    assert Flurry.Git.View.object_id("commit", Base.decode64!(a.raw)) == a.git
    change = Changesets.get(repo, second)

    assert_raise Flurry.Error, fn ->
      Flurry.Git.View.attach(repo, change, %{
        "id" => a.git,
        "raw" => Base.encode64("forged"),
        "modes" => %{}
      })
    end
  end

  test "ref names cannot alias by case or directory prefix", %{user: user, repository: repo} do
    head = push(repo, user, "feature", nil, [commit(nil, "a", "a")])["head"]

    assert_raise Flurry.Error, fn ->
      push(repo, user, "Feature", nil, [commit(head, "b", "b")])
    end

    assert_raise Flurry.Error, fn ->
      push(repo, user, "feature/nested", nil, [commit(head, "b", "b")])
    end

    push(repo, user, "group/a", nil, [commit(head, "group", "group")])

    assert_raise Flurry.Error, fn ->
      push(repo, user, "Group/b", nil, [commit(head, "other", "other")])
    end

    Refs.tag(repo, user, %{"name" => "v1", "target" => head})
    assert_raise Flurry.Error, fn -> Refs.tag(repo, user, %{"name" => "V1", "target" => head}) end

    assert_raise Flurry.Error, fn ->
      Refs.tag(repo, user, %{"name" => "v1/nested", "target" => head})
    end
  end
end
