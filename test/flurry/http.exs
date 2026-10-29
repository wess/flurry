defmodule Flurry.HttpTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias Flurry.{Auth, Repo}
  alias Flurry.Engine.Repositories
  alias Flurry.Git.{Import, SmartHttp}
  alias Flurry.Http.Router
  alias Flurry.Security.Tokens

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    id = Ecto.UUID.generate() |> String.replace("-", "")

    {user, token} =
      Auth.signup(%{
        "name" => "Owner",
        "username" => "u" <> id,
        "email" => id <> "@example.test",
        "password" => "correct horse battery staple"
      })

    %{user: user, token: token}
  end

  defp call(method, path, body \\ nil, token \\ nil) do
    conn =
      conn(method, path, if(body, do: Jason.encode!(body), else: nil))
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, Router.init([]))
  end

  defp call_with_key(path, body, token, key) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("idempotency-key", key)
    |> Router.call(Router.init([]))
  end

  test "session resolves only the current user and logout revokes the token", %{
    user: user,
    token: token
  } do
    response = call(:get, "/api/session", nil, token)
    assert response.status == 200
    data = Jason.decode!(response.resp_body)
    assert data["user"]["id"] == user.id
    refute Map.has_key?(data["user"], "password")
    assert call(:delete, "/api/session", nil, token).status == 200
    assert Auth.resolve(token) == nil
  end

  test "authorization headers cannot be ambiguous or fall back to a session cookie", %{
    token: token
  } do
    invalid =
      assert_raise Flurry.Error, fn ->
        conn(:get, "/api/repositories")
        |> put_req_cookie("flurry", token)
        |> put_req_header("authorization", "Token invalid")
        |> Router.call(Router.init([]))
      end

    assert invalid.status == 401

    duplicate =
      conn(:get, "/api/repositories")
      |> put_req_header("authorization", "Bearer " <> token)

    duplicate = %{
      duplicate
      | req_headers: [{"authorization", "Bearer another"} | duplicate.req_headers]
    }

    error = assert_raise Flurry.Error, fn -> Router.call(duplicate, Router.init([])) end
    assert error.status == 400
  end

  test "repository-scoped tokens authenticate smart HTTP Git paths", %{user: user} do
    repository = Repositories.create(user, %{"name" => "scopedgit"})
    other = Repositories.create(user, %{"name" => "othergit"})

    %{token: token} =
      Tokens.create(user, %{
        "name" => "Git client",
        "access" => "write",
        "repository_id" => repository.id,
        "days" => 1,
        "password" => "correct horse battery staple"
      })

    response =
      call(
        :get,
        "/repositories/#{repository.id}.git/info/refs?service=git-upload-pack",
        nil,
        token
      )

    assert response.status == 200

    error =
      assert_raise Flurry.Error, fn ->
        call(:get, "/repositories/#{other.id}.git/info/refs?service=git-upload-pack", nil, token)
      end

    assert error.status == 403
  end

  test "smart HTTP decodes Git gzip request envelopes" do
    payload = "0000want a revision\n"

    conn =
      conn(:post, "/repositories/example.git/git-receive-pack", :zlib.gzip(payload))
      |> put_req_header("content-encoding", "gzip")

    assert {^payload, _conn} = SmartHttp.read_body(conn)
  end

  test "smart HTTP accepts an empty receive-pack probe", %{user: user} do
    repository = Repositories.create(user, %{"name" => "gitprobe"})
    assert is_binary(SmartHttp.receive(repository, user, "0000"))
  end

  test "a first Git push imports ordinary repositories beyond native submission limits", %{
    user: user
  } do
    repository = Repositories.create(user, %{"name" => "gitimport"})
    directory = Path.join(System.tmp_dir!(), "flurrygit" <> Ecto.UUID.generate())
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {_, 0} = System.cmd("git", ["-C", directory, "init", "--quiet", "--initial-branch=main"])
    {_, 0} = System.cmd("git", ["-C", directory, "config", "user.name", "Git author"])
    {_, 0} = System.cmd("git", ["-C", directory, "config", "user.email", "git@example.test"])

    for number <- 1..101 do
      File.write!(Path.join(directory, "file-#{number}.txt"), Integer.to_string(number))
    end

    {_, 0} = System.cmd("git", ["-C", directory, "add", "."])
    {_, 0} = System.cmd("git", ["-C", directory, "commit", "--quiet", "-m", "Initial import"])
    {commit, 0} = System.cmd("git", ["-C", directory, "rev-parse", "HEAD"])
    commit = String.trim(commit)

    result =
      Import.apply(
        repository,
        user,
        directory,
        String.duplicate("0", 40) <> " #{commit} refs/heads/main\n"
      )

    assert result["head"] == Repositories.head(repository)
    assert map_size(result["commits"]) == 1
  end

  test "authenticated API traffic is bounded per account", %{token: token} do
    previous = Application.get_env(:flurry, :api_rate_limit)
    Application.put_env(:flurry, :api_rate_limit, 2)
    on_exit(fn -> Application.put_env(:flurry, :api_rate_limit, previous) end)

    assert call(:get, "/api/repositories", nil, token).status == 200
    assert call(:get, "/api/repositories", nil, token).status == 200

    error =
      assert_raise Flurry.Error, fn -> call(:get, "/api/repositories", nil, token) end

    assert error.status == 429
  end

  test "responses include isolation and browser capability headers" do
    response = call(:get, "/api/health")
    assert get_resp_header(response, "cross-origin-opener-policy") == ["same-origin"]
    assert get_resp_header(response, "cross-origin-resource-policy") == ["same-origin"]

    assert get_resp_header(response, "permissions-policy") == [
             "camera=(), microphone=(), geolocation=(), payment=()"
           ]
  end

  test "public profiles contain public repositories and no credentials", %{user: user} do
    Repositories.create(user, %{"name" => "private"})
    Repositories.create(user, %{"name" => "public", "visibility" => "public"})
    response = call(:get, "/api/profiles/#{user.username}")
    data = Jason.decode!(response.resp_body)
    assert Enum.map(data["repositories"], & &1["name"]) == ["public"]
    refute Map.has_key?(data, "email")
    refute Map.has_key?(data, "password")
  end

  test "organizations own repositories through the public API", %{token: token} do
    created =
      call(
        :post,
        "/api/organizations",
        %{"name" => "Flurry Tools", "slug" => "flurry-tools"},
        token
      )

    assert created.status == 201
    organization = Jason.decode!(created.resp_body)

    repository =
      call(
        :post,
        "/api/repositories",
        %{"name" => "engine", "organization_id" => organization["id"]},
        token
      )

    assert repository.status == 201
    body = Jason.decode!(repository.resp_body)
    assert body["owner"]["kind"] == "organization"
    assert body["owner"]["username"] == "flurry-tools"

    listed =
      call(:get, "/api/organizations", nil, token) |> Map.fetch!(:resp_body) |> Jason.decode!()

    assert [%{"slug" => "flurry-tools", "role" => "owner"}] = listed["organizations"]
  end

  test "HTTP submission, approval, landing and file retrieval", %{user: user, token: token} do
    repo = Repositories.create(user, %{"name" => "sample"})
    prefix = "/api/repositories/#{repo.id}"

    body = %{
      "base" => nil,
      "message" => "First change",
      "files" => [%{"path" => "readme.md", "content" => "hello\n"}]
    }

    result = call_with_key(prefix <> "/changesets", body, token, "first-change")

    assert result.status == 201
    submitted = Jason.decode!(result.resp_body)

    assert Jason.decode!(
             call_with_key(prefix <> "/changesets", body, token, "first-change").resp_body
           ) == submitted

    review = submitted["review_id"]

    evaluation =
      call(
        :post,
        prefix <> "/changesets/#{submitted["changeset"]["id"]}/evaluations",
        %{
          "context" => "quality/tests",
          "state" => "success",
          "summary" => "Passed",
          "pass" => 12,
          "fail" => 0
        },
        token
      )

    assert evaluation.status == 201

    evaluation_list =
      call(
        :get,
        prefix <> "/changesets/#{submitted["changeset"]["id"]}/evaluations",
        nil,
        token
      )
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert [%{"summary" => "Passed", "state" => "success"}] =
             evaluation_list["evaluations"]

    activity =
      call(:get, prefix <> "/activity", nil, token)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert Enum.any?(activity["events"], &(&1["type"] == "evaluation.created"))

    status =
      call(
        :put,
        prefix <> "/changesets/#{submitted["changeset"]["id"]}/statuses",
        %{"context" => "quality/tests", "state" => "success", "description" => "Passed"},
        token
      )

    assert status.status == 200

    summary =
      call(:get, prefix <> "/changesets/#{submitted["changeset"]["id"]}/statuses", nil, token)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert summary["state"] == "success"
    assert call(:post, prefix <> "/reviews/#{review}/approve", %{}, token).status == 200
    assert call(:post, prefix <> "/reviews/#{review}/land", %{}, token).status == 200
    tree = call(:get, prefix <> "/tree", nil, token) |> Map.fetch!(:resp_body) |> Jason.decode!()
    assert hd(tree["entries"])["name"] == "readme.md"

    file =
      call(:get, prefix <> "/file?path=readme.md", nil, token)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert file["content"] == "hello\n"

    assert call(:get, prefix <> "/file?path=readme.md&raw=true", nil, token).resp_body ==
             "hello\n"

    search =
      call(:get, prefix <> "/search?query=HELLO", nil, token)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert [%{"line" => 1, "path" => "readme.md", "text" => "hello"}] = search["matches"]

    paths =
      call(:get, prefix <> "/search?type=path&query=README", nil, token)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert paths["paths"] == ["readme.md"]

    archive = call(:get, prefix <> "/archive", nil, token)
    assert archive.status == 200
    assert get_resp_header(archive, "content-type") == ["application/gzip; charset=utf-8"]

    assert {:ok, [{name, "hello\n"}]} =
             :erl_tar.extract({:binary, archive.resp_body}, [:compressed, :memory])

    assert List.to_string(name) =~ ~r|\Asample-[0-9a-f]{12}/readme\.md\z|
  end

  test "cross-origin requests cannot mutate the server", %{token: token} do
    conn =
      conn(:post, "/api/repositories", Jason.encode!(%{"name" => "nope"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "https://example.org")
      |> put_req_header("authorization", "Bearer " <> token)

    assert_raise Flurry.Error, fn -> Router.call(conn, Router.init([])) end
  end

  test "configured public origin is accepted behind an internal HTTP proxy", %{token: token} do
    previous = Application.get_env(:flurry, :public_url)
    Application.put_env(:flurry, :public_url, "https://flurry.codes")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:flurry, :public_url, previous),
        else: Application.delete_env(:flurry, :public_url)
    end)

    response =
      conn(:post, "/api/repositories", Jason.encode!(%{"name" => "proxied"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "https://flurry.codes")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))

    assert response.status == 201
  end

  test "forwarded client addresses are accepted only from configured proxies" do
    previous = Application.get_env(:flurry, :trusted_proxies)
    Application.put_env(:flurry, :trusted_proxies, [{10, 0, 0, 1}])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:flurry, :trusted_proxies, previous),
        else: Application.delete_env(:flurry, :trusted_proxies)
    end)

    trusted =
      conn(:get, "/")
      |> Map.put(:remote_ip, {10, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "203.0.113.8")

    untrusted =
      conn(:get, "/")
      |> Map.put(:remote_ip, {10, 0, 0, 2})
      |> put_req_header("x-forwarded-for", "203.0.113.9")

    assert Flurry.Http.Client.address(trusted) == {203, 0, 113, 8}
    assert Flurry.Http.Client.address(untrusted) == {10, 0, 0, 2}
  end

  test "large-file batch transport streams verified objects and supports locks", %{
    user: user,
    token: token
  } do
    repository = Repositories.create(user, %{"name" => "largefiles", "visibility" => "public"})
    content = :crypto.strong_rand_bytes(2_000_000)
    oid = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    base = "/repositories/#{repository.id}.git/info/lfs"

    batch =
      call(
        :post,
        base <> "/objects/batch",
        %{"operation" => "upload", "objects" => [%{"oid" => oid, "size" => byte_size(content)}]},
        token
      )

    assert batch.status == 200
    object = Jason.decode!(batch.resp_body)["objects"] |> hd()
    assert object["actions"]["upload"]["href"] =~ oid

    uploaded =
      conn(:put, base <> "/objects/" <> oid, content)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))

    assert uploaded.status == 200

    download_batch =
      call(:post, base <> "/objects/batch", %{
        "operation" => "download",
        "objects" => [%{"oid" => oid, "size" => byte_size(content)}]
      })
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert download_batch["objects"] |> hd() |> get_in(["actions", "download", "href"])
    assert call(:get, base <> "/objects/" <> oid).resp_body == content

    lock = call(:post, base <> "/locks", %{"path" => "media/video.bin"}, token)
    assert lock.status == 201
    lock_id = Jason.decode!(lock.resp_body)["lock"]["id"]

    verified =
      call(:post, base <> "/locks/verify", %{}, token)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert get_in(verified, ["ours", Access.at(0), "path"]) == "media/video.bin"
    assert call(:post, base <> "/locks/#{lock_id}/unlock", %{}, token).status == 200

    on_exit(fn -> File.rm(Flurry.Git.Lfs.path(oid)) end)
  end

  test "unauthorized access and malformed identifiers return deliberate errors" do
    error = assert_raise Plug.Conn.WrapperError, fn -> call(:get, "/api/repositories") end
    assert error.reason.status == 401
    error = assert_raise Plug.Conn.WrapperError, fn -> call(:get, "/api/repositories/invalid") end
    assert error.reason.status == 404
    assert call(:get, "/api/unknown").status == 404
  end

  test "source links respect repository visibility and only owners can transfer", %{
    user: user,
    token: token
  } do
    repo = Repositories.create(user, %{"name" => "linked"})

    Repo.insert!(%Flurry.Schema.Source{
      repository_id: repo.id,
      url: "https://git.example.com/example/repo.git"
    })

    error =
      assert_raise Plug.Conn.WrapperError, fn ->
        call(:get, "/api/repositories/#{repo.id}/source")
      end

    assert error.reason.status == 404
    response = call(:get, "/api/repositories/#{repo.id}/source", nil, token)
    source = Jason.decode!(response.resp_body)["source"]
    assert source["url"] == "https://git.example.com/example/repo.git"
    refute Map.has_key?(source, "token")
    refute Map.has_key?(source, "push_root")

    {stranger, stranger_token} =
      Auth.signup(%{
        "name" => "Other",
        "username" => "other" <> String.replace(Ecto.UUID.generate(), "-", ""),
        "email" => Ecto.UUID.generate() <> "@example.test",
        "password" => "correct horse battery staple"
      })

    assert stranger.id != user.id

    error =
      assert_raise Plug.Conn.WrapperError, fn ->
        call(:post, "/api/repositories/#{repo.id}/source/push", %{"head" => nil}, stranger_token)
      end

    assert error.reason.status == 404
  end

  test "import requires authentication and refuses embedded credentials", %{token: token} do
    error = assert_raise Plug.Conn.WrapperError, fn -> call(:post, "/api/imports", %{}) end
    assert error.reason.status == 401

    error =
      assert_raise Plug.Conn.WrapperError, fn ->
        call(
          :post,
          "/api/imports",
          %{"url" => "https://secret@git.example.com/owner/repo", "name" => "invalid"},
          token
        )
      end

    assert error.reason.status == 422
  end
end
