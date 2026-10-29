defmodule Flurry.SettingsTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  require Ecto.Query
  alias Flurry.{Auth, Repo, Profiles, Instance}
  alias Flurry.Security.{Accounts, Agents, Sessions, Tokens, Factor, Vault}
  alias Flurry.Engine.{Repositories, Settings, Changesets, Reviews}
  @password "correct horse battery staple"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    {user, token} = new_user()
    %{user: user, token: token}
  end

  defp new_user do
    id = String.replace(Ecto.UUID.generate(), "-", "")

    Auth.signup(%{
      "name" => "Settings user",
      "username" => "u" <> id,
      "email" => id <> "@example.test",
      "password" => @password
    })
  end

  defp repo(user), do: Repositories.create(user, %{"name" => "sample"})

  defp submit(repository, user) do
    Changesets.submit(repository, user, %{
      "base" => Repositories.head(repository),
      "message" => "Change",
      "files" => [%{"path" => "readme.md", "content" => Ecto.UUID.generate()}]
    })
  end

  defp api(method, path, token, body \\ nil) do
    conn(method, path, if(body, do: Jason.encode!(body)))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> Flurry.Http.Router.call([])
  end

  defp denied(status, function) do
    try do
      function.()
      flunk("Expected a denied request")
    rescue
      error in Flurry.Error -> assert error.status == status
      error in Plug.Conn.WrapperError -> assert error.reason.status == status
    end
  end

  test "credential updates require the old password and revoke sessions and tokens", %{
    user: user,
    token: old
  } do
    pat =
      Tokens.create(user, %{
        "password" => @password,
        "name" => "Client",
        "access" => "write",
        "days" => 1
      })

    assert Sessions.credential(pat.token, true)

    assert_raise Flurry.Error, fn ->
      Accounts.change(user, %{"password" => "wrong", "new_password" => "a different password"})
    end

    email = Ecto.UUID.generate() <> "@example.test"

    {changed, fresh} =
      Accounts.change(user, %{
        "password" => @password,
        "new_password" => "a different password",
        "email" => email
      })

    assert changed.email == email
    assert Auth.resolve(old) == nil
    assert Sessions.credential(pat.token, true) == nil
    assert Auth.resolve(fresh).id == user.id
    assert_raise Flurry.Error, fn -> Auth.login(%{"email" => email, "password" => @password}) end

    assert elem(Auth.login(%{"email" => email, "password" => "a different password"}), 0).id ==
             user.id
  end

  test "users can inspect and revoke only their own sessions", %{user: user, token: current} do
    {_other, other_token} = new_user()
    second = Sessions.issue(user, "Another browser")
    sessions = Sessions.list(user, current)
    assert length(sessions) == 2
    assert Enum.count(sessions, & &1.current) == 1
    target = Enum.find(sessions, &(not &1.current))
    Sessions.revoke(user, target.id)
    assert Auth.resolve(second) == nil
    assert Auth.resolve(other_token)
    Sessions.revoke_others(user, current)
    assert Auth.resolve(current)
  end

  test "read-only scoped API tokens cannot write, change settings, or read another private repo",
       %{user: user} do
    repository = repo(user)
    other = Repositories.create(user, %{"name" => "other"})

    token =
      Tokens.create(user, %{
        "password" => @password,
        "name" => "Read",
        "access" => "read",
        "days" => 30,
        "repository_id" => repository.id
      })

    assert api(:get, "/api/repositories/#{repository.id}", token.token).status == 200
    listed = api(:get, "/api/repositories", token.token).resp_body |> Jason.decode!()
    assert Enum.map(listed["repositories"], & &1["id"]) == [repository.id]
    denied(403, fn -> api(:get, "/api/repositories/#{other.id}", token.token) end)

    denied(403, fn ->
      api(:post, "/api/repositories/#{repository.id}/changesets", token.token, %{})
    end)

    denied(403, fn -> api(:get, "/api/settings/account", token.token) end)
    Tokens.revoke(user, token.id)
    assert Sessions.credential(token.token, true) == nil
  end

  test "write tokens can submit code while repository and instance settings stay protected", %{
    user: user
  } do
    repository = repo(user)

    token =
      Tokens.create(user, %{
        "password" => @password,
        "name" => "Writer",
        "access" => "write",
        "days" => 1,
        "repository_id" => repository.id
      })

    response =
      api(:post, "/api/repositories/#{repository.id}/changesets", token.token, %{
        "base" => nil,
        "message" => "API change",
        "files" => [%{"path" => "a", "content" => "a"}]
      })

    assert response.status == 201

    denied(403, fn ->
      api(:patch, "/api/repositories/#{repository.id}", token.token, %{"name" => "changed"})
    end)

    denied(403, fn -> api(:get, "/api/admin", token.token) end)
    denied(403, fn -> api(:post, "/api/repositories", token.token, %{"name" => "escape"}) end)
    refute inspect(Tokens.list(user)) =~ token.token
  end

  test "agent accounts use one-time credentials and only assigned repository access", %{
    user: owner
  } do
    repository = repo(owner)

    agent =
      Agents.create(owner, %{
        "name" => "Release worker",
        "username" => "release." <> String.slice(Ecto.UUID.generate(), 0, 8),
        "days" => 30,
        "password" => @password
      })

    assert String.starts_with?(agent.token, "fla_")
    refute inspect(Agents.list(owner)) =~ agent.token
    credential = Sessions.credential(agent.token, true)
    assert credential.kind == :agent
    assert credential.user.account_type == "agent"

    denied(404, fn -> api(:get, "/api/repositories/#{repository.id}", agent.token) end)
    Settings.member(repository, owner, %{"username" => agent.username, "role" => "write"})

    response =
      api(:post, "/api/repositories/#{repository.id}/changesets", agent.token, %{
        "base" => nil,
        "message" => "Automated change",
        "files" => [%{"path" => "release.txt", "content" => "ready"}]
      })

    assert response.status == 201
    denied(403, fn -> api(:get, "/api/settings/account", agent.token) end)
    denied(403, fn -> api(:post, "/api/repositories", agent.token, %{"name" => "escape"}) end)

    rotated = Agents.rotate(owner, agent.id, %{"password" => @password, "days" => 14})
    assert Sessions.credential(agent.token, true) == nil
    assert Sessions.credential(rotated.token, true)

    Agents.revoke(owner, agent.id, %{"password" => @password})
    assert Sessions.credential(rotated.token, true) == nil
    assert_raise Flurry.Error, fn -> Repositories.get(credential.user, repository.id) end
  end

  test "two-factor setup encrypts secrets, rejects reused codes, and consumes recovery codes", %{
    user: user,
    token: old
  } do
    previous = Application.get_env(:flurry, :encryption_key)
    Application.put_env(:flurry, :encryption_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:flurry, :encryption_key, previous),
        else: Application.delete_env(:flurry, :encryption_key)
    end)

    setup = Factor.prepare(user, %{"password" => @password})
    secret = Base.decode32!(setup.secret, padding: false)
    stored = Repo.get!(Flurry.Schema.User, user.id)
    refute stored.totp_pending == secret
    assert Vault.decrypt(stored.totp_pending) == secret
    code = NimbleTOTP.verification_code(secret)
    {enabled, fresh, codes} = Factor.enable(user, %{"password" => @password, "code" => code})
    assert length(codes) == 10
    assert Auth.resolve(old) == nil
    assert Auth.resolve(fresh)

    assert_raise Flurry.Error, fn ->
      Auth.login(%{"email" => user.email, "password" => @password, "code" => code})
    end

    {enabled, replacement_token, replacement_codes} =
      Factor.regenerate(enabled, %{"password" => @password, "code" => hd(codes)})

    assert length(replacement_codes) == 10
    assert Auth.resolve(replacement_token)

    {_, login} =
      Auth.login(%{
        "email" => user.email,
        "password" => @password,
        "code" => hd(replacement_codes)
      })

    assert Auth.resolve(login)

    assert_raise Flurry.Error, fn ->
      Auth.login(%{
        "email" => user.email,
        "password" => @password,
        "code" => Enum.at(codes, 1)
      })
    end

    {disabled, _} =
      Factor.disable(enabled, %{
        "password" => @password,
        "code" => Enum.at(replacement_codes, 1)
      })

    assert disabled.totp_secret == nil
  end

  test "collaborators have effective roles and independent approval survives permission changes",
       %{user: owner} do
    {writer, _} = new_user()
    {maintainer, _} = new_user()
    repository = repo(owner)
    Settings.member(repository, owner, %{"username" => writer.username, "role" => "write"})
    Settings.member(repository, owner, %{"username" => maintainer.username, "role" => "maintain"})
    assert Repositories.get(writer, repository.id, :write)
    assert_raise Flurry.Error, fn -> Repositories.get(writer, repository.id, :review) end
    assert Enum.any?(Repositories.list(writer), &(&1.id == repository.id))
    repository = Settings.update(repository, owner, %{"allow_self_approval" => false})
    change = submit(repository, owner)
    assert_raise Flurry.Error, fn -> Reviews.approve(repository, change.review_id, owner) end
    Reviews.approve(repository, change.review_id, maintainer)
    Settings.member(repository, owner, %{"username" => maintainer.username, "role" => "read"})
    assert_raise Flurry.Error, fn -> Reviews.land(repository, change.review_id, owner) end
    Settings.member(repository, owner, %{"username" => maintainer.username, "role" => "maintain"})
    assert Reviews.land(repository, change.review_id, owner).head
  end

  test "archiving blocks writes and removing/restoring preserves private immutable history", %{
    user: user
  } do
    repository = repo(user)
    change = submit(repository, user)
    Reviews.approve(repository, change.review_id)
    head = Reviews.land(repository, change.review_id).head
    Settings.lifecycle(repository, user, %{"action" => "archive"})
    assert_raise Flurry.Error, fn -> submit(repository, user) end

    Settings.lifecycle(repository, user, %{
      "action" => "remove",
      "confirm" => repository.name,
      "password" => @password
    })

    assert_raise Flurry.Error, fn -> Repositories.get(user, repository.id) end
    assert length(Settings.removed(user)) == 1
    Settings.restore(user, repository.id)
    restored = Repositories.get(user, repository.id)
    assert restored.archived and restored.visibility == "private"
    assert Repositories.head(restored) == head
  end

  test "profile privacy and hidden activity are enforced on public reads", %{user: user} do
    updated =
      Accounts.preferences(user, %{
        "theme" => "dark",
        "default_visibility" => "private",
        "wrap_code" => true,
        "private_profile" => true,
        "hide_activity" => true
      })

    assert_raise Flurry.Error, fn -> Profiles.get(user.username, nil) end
    assert Profiles.get(user.username, updated).id == user.id
    assert Auth.me(updated).preferences["theme"] == "dark"
    refute Map.has_key?(Auth.public(updated), :email)
  end

  test "administration enforces registration, public-repo policy, and active administrator continuity",
       %{user: user} do
    admin = user |> Ecto.Changeset.change(admin: true) |> Repo.update!()

    settings =
      Map.merge(Instance.public(), %{git_hosts: Instance.hosts()})
      |> Jason.encode!()
      |> Jason.decode!()

    Instance.update(
      admin,
      Map.merge(settings, %{"registration" => false, "allow_public" => false})
    )

    assert_raise Flurry.Error, fn -> new_user() end

    assert_raise Flurry.Error, fn ->
      Repositories.create(admin, %{"name" => "public", "visibility" => "public"})
    end

    assert_raise Flurry.Error, fn -> Instance.update(user, settings) end

    Repo.update_all(Ecto.Query.from(u in Flurry.Schema.User, where: u.id != ^admin.id),
      set: [admin: false]
    )

    assert_raise Flurry.Error, fn ->
      Instance.update_user(admin, admin.id, %{"admin" => false, "disabled" => false})
    end
  end

  test "settings endpoints are usable through browser sessions and source unlink uses its specific route",
       %{user: user, token: token} do
    assert api(:get, "/api/settings/account", token).status == 200
    assert api(:get, "/api/settings/sessions", token).status == 200
    repository = repo(user)

    Repo.insert!(%Flurry.Schema.Source{
      repository_id: repository.id,
      url: "https://git.example.com/example/repo.git"
    })

    response =
      api(:post, "/api/repositories/#{repository.id}/source/unlink", token, %{
        "password" => @password
      })

    assert response.status == 200
    assert Flurry.Engine.Sources.get(repository) == nil
    denied(403, fn -> api(:get, "/api/admin", token) end)
  end
end
