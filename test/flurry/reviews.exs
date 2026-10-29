defmodule Flurry.ReviewPolicyTest do
  use ExUnit.Case, async: false
  alias Flurry.{Auth, Repo}
  alias Flurry.Engine.{Changesets, Repositories, Reviews}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  defp user(label) do
    id = Ecto.UUID.generate() |> String.replace("-", "")

    {user, _} =
      Auth.signup(%{
        "name" => label,
        "username" => "u" <> id,
        "email" => id <> "@example.test",
        "password" => "correct horse battery staple"
      })

    user
  end

  defp submit(repository, user, base, content) do
    Changesets.submit(repository, user, %{
      "base" => base,
      "message" => "Update file",
      "files" => [%{"path" => "readme.md", "content" => content}]
    })
  end

  defp maintain(repository, user) do
    Repo.insert_all("members", [
      %{
        repository_id: Ecto.UUID.dump!(repository.id),
        user_id: Ecto.UUID.dump!(user.id),
        role: "maintain"
      }
    ])
  end

  test "multiple current approvals satisfy policy while a rejection blocks landing" do
    owner = user("Owner")
    first = user("First reviewer")
    second = user("Second reviewer")
    repository = Repositories.create(owner, %{"name" => "policy"})
    maintain(repository, first)
    maintain(repository, second)

    repository =
      repository
      |> Ecto.Changeset.change(required_approvals: 2)
      |> Repo.update!()

    submitted = submit(repository, owner, nil, "hello\n")

    detail =
      Reviews.request_reviewers(repository, submitted.review_id, owner, [first.id, second.id])

    assert Enum.map(detail.requested_reviewers, & &1.user.name) == [
             "First reviewer",
             "Second reviewer"
           ]

    assert Reviews.approve(repository, submitted.review_id, owner).status == "open"
    assert Reviews.approve(repository, submitted.review_id, first).status == "approved"
    assert Reviews.reject(repository, submitted.review_id, second).status == "changes_requested"

    assert_raise Flurry.Error, ~r/Resolve requested changes/, fn ->
      Reviews.land(repository, submitted.review_id, owner)
    end

    assert Reviews.approve(repository, submitted.review_id, second).status == "approved"
    landed = Reviews.land(repository, submitted.review_id, owner)
    assert landed.head == submitted.changeset.id
    assert landed.review.approvals == 3
    assert landed.review.rejections == 0
    assert landed.review.required_approvals == 2
  end

  test "revision changes stale old decisions and inline comments require a current text line" do
    owner = user("Owner")
    repository = Repositories.create(owner, %{"name" => "revision"})
    first = submit(repository, owner, nil, "first\nline\n")
    assert Reviews.approve(repository, first.review_id, owner).status == "approved"

    next = submit(repository, owner, nil, "next\nline\n")
    next_review = Reviews.get(repository, next.review_id)
    Repo.delete!(next_review)

    revised = Reviews.revise(repository, first.review_id, owner, next.changeset.id)
    assert revised.status == "open"

    detail = Reviews.detail(repository, revised)
    assert [%{current: false, decision: "approve", revision: old}] = detail.decisions
    assert old == first.changeset.id
    assert detail.approvals == 0

    detail =
      Reviews.comment(repository, owner, first.review_id, %{
        "body" => "This line needs context.",
        "revision" => next.changeset.id,
        "path" => "readme.md",
        "side" => "after",
        "line" => 2
      })

    assert [%{revision: revision, path: "readme.md", side: "after", line: 2}] = detail.comments
    assert revision == next.changeset.id

    assert_raise Flurry.Error, ~r/stale/, fn ->
      Reviews.comment(repository, owner, first.review_id, %{
        "body" => "Old line",
        "revision" => first.changeset.id,
        "path" => "readme.md",
        "side" => "after",
        "line" => 1
      })
    end

    assert_raise Flurry.Error, ~r/outside/, fn ->
      Reviews.comment(repository, owner, first.review_id, %{
        "body" => "Missing line",
        "revision" => next.changeset.id,
        "path" => "readme.md",
        "side" => "after",
        "line" => 99
      })
    end
  end
end
