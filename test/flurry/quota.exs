defmodule Flurry.QuotaTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Flurry.{Auth, Instance, Quota, Repo}
  alias Flurry.Engine.{Changesets, Repositories, Settings}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    {owner, _} = user()

    Repo.update_all(Flurry.Schema.Instance,
      set: [
        owner_id: owner.id,
        file_bytes: 10_485_760,
        project_storage_bytes: 1_073_741_824,
        account_storage_bytes: 1_073_741_824
      ]
    )

    {user, _} = user()
    %{owner: owner, user: user}
  end

  defp user do
    id = String.replace(Ecto.UUID.generate(), "-", "")

    Auth.signup(%{
      "name" => "Quota user",
      "username" => "q" <> id,
      "email" => id <> "@example.test",
      "password" => "correct horse battery staple"
    })
  end

  defp submit(repository, user, content) do
    Changesets.submit(repository, user, %{
      "base" => nil,
      "message" => "Quota",
      "files" => [%{"path" => "a", "content" => content}]
    })
  end

  test "first owner identity is persistent and protected", %{owner: owner, user: user} do
    Instance.claim(user)
    assert Instance.owner?(owner)
    refute Instance.owner?(user)
    admin = user |> Ecto.Changeset.change(admin: true) |> Repo.update!()

    assert_raise Flurry.Error, fn ->
      Instance.update_user(admin, owner.id, %{"admin" => false, "disabled" => false})
    end

    assert_raise Flurry.Error, fn ->
      Instance.update_user(admin, owner.id, %{"admin" => true, "disabled" => true})
    end

    assert Auth.me(owner).owner
  end

  test "file, project, and account limits preserve existing history", %{user: user} do
    Repo.update_all(Flurry.Schema.Instance,
      set: [file_bytes: 6, project_storage_bytes: 5, account_storage_bytes: 9]
    )

    first = Repositories.create(user, %{"name" => "projectcap"})
    second = Repositories.create(user, %{"name" => "projectroom"})
    third = Repositories.create(user, %{"name" => "accountcap"})
    accepted = submit(first, user, "1234")
    assert Quota.usage(user).bytes == 4
    assert_raise Flurry.Error, ~r/Project storage limit/, fn -> submit(first, user, "12") end
    submit(second, user, "12345")
    assert Quota.usage(user).bytes == 9
    assert_raise Flurry.Error, ~r/Account storage limit/, fn -> submit(third, user, "x") end
    assert Changesets.get(first, accepted.changeset.id)

    Settings.lifecycle(first, user, %{
      "action" => "remove",
      "confirm" => first.name,
      "password" => "correct horse battery staple"
    })

    assert Quota.usage(user) == %{bytes: 9, repositories: 2}
  end

  test "zero retained-storage limits are unlimited while file limits remain enforced", %{
    user: user
  } do
    Repo.update_all(Flurry.Schema.Instance,
      set: [file_bytes: 5, project_storage_bytes: 0, account_storage_bytes: 0]
    )

    repository = Repositories.create(user, %{"name" => "unlimited"})
    submit(repository, user, "12345")

    count =
      Repo.aggregate(
        from(c in Flurry.Schema.Changeset, where: c.repository_id == ^repository.id),
        :count
      )

    assert_raise Flurry.Error, fn -> submit(repository, user, "123456") end

    assert Repo.aggregate(
             from(c in Flurry.Schema.Changeset, where: c.repository_id == ^repository.id),
             :count
           ) == count
  end
end
