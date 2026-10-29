defmodule Flurry.Git.Fixture do
  alias Flurry.Git.{Command, Transport}

  def fetch(source, _credentials, directory) do
    remote = Application.fetch_env!(:flurry, :git_fixture)
    Command.run(directory, ["init", "--bare", "--quiet", "--template=", "."])

    {_, 0} =
      System.cmd("git", [
        "-C",
        directory,
        "fetch",
        "--quiet",
        remote,
        "refs/heads/" <> (source.branch || "main")
      ])

    snapshot = Transport.snapshot(directory, source.branch || "main")

    if source.operation == "push" do
      if callback = Application.get_env(:flurry, :git_on_fetch), do: callback.()
    end

    Map.put(snapshot, :full_history, true)
  end

  def push(source, _credentials, directory, commit) do
    remote = Application.fetch_env!(:flurry, :git_fixture)

    if Application.get_env(:flurry, :git_race) do
      working = Application.fetch_env!(:flurry, :git_working)
      File.write!(Path.join(working, "race.txt"), "racing upstream change")
      {_, 0} = System.cmd("git", ["-C", working, "add", "."])

      {_, 0} =
        System.cmd("git", ["-C", working, "commit", "--quiet", "-m", "Concurrent upstream change"])

      {_, 0} = System.cmd("git", ["-C", working, "push", "--quiet", remote, "HEAD:main"])
    end

    case System.cmd(
           "git",
           [
             "-C",
             directory,
             "push",
             "--quiet",
             "--force-with-lease=refs/heads/#{source.branch}:#{source.commit}",
             remote,
             "#{commit}:refs/heads/#{source.branch}"
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      _ -> Flurry.Error.fail("Upstream advanced while pushing; pull updates first", 409)
    end

    if Application.get_env(:flurry, :git_after_push),
      do: Flurry.Error.fail("Connection lost after push; retry to confirm")
  end
end

defmodule Flurry.SourcesTest do
  use ExUnit.Case, async: false
  alias Flurry.{Auth, Repo}
  alias Flurry.Engine.{Repositories, Changesets, Reviews, Sources}
  alias Flurry.Schema.Source
  alias Flurry.Git.{Remote, Worker}
  alias Flurry.Store.{Tree, Objects}

  setup tags do
    if tags[:job],
      do: Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto),
      else: Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    id = Ecto.UUID.generate() |> String.replace("-", "")
    directory = Path.join(System.tmp_dir!(), "flurrytest" <> id)
    File.mkdir_p!(directory)
    working = Path.join(directory, "working")
    remote = Path.join(directory, "remote")
    git(directory, ["init", "--quiet", "--initial-branch=main", working])
    git(directory, ["init", "--quiet", "--bare", "--initial-branch=main", remote])
    git(working, ["config", "user.name", "Upstream author"])
    git(working, ["config", "user.email", "upstream@example.test"])
    File.write!(Path.join(working, "readme.md"), "upstream original\n")
    File.write!(Path.join(working, "script.sh"), "echo hello\n")
    File.chmod!(Path.join(working, "script.sh"), 0o755)
    git(working, ["add", "."])
    git(working, ["commit", "--quiet", "-m", "Original history"])
    git(working, ["push", "--quiet", remote, "HEAD:main"])
    Application.put_env(:flurry, :git_transport, Flurry.Git.Fixture)
    Application.put_env(:flurry, :git_fixture, remote)
    Application.put_env(:flurry, :git_working, working)

    on_exit(fn ->
      if tags[:job], do: Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

      for key <- [
            :git_transport,
            :git_fixture,
            :git_working,
            :git_race,
            :git_after_push,
            :git_on_fetch
          ],
          do: Application.delete_env(:flurry, key)

      File.rm_rf!(directory)
    end)

    {user, _} =
      Auth.signup(%{
        "name" => "Importer",
        "username" => "u" <> id,
        "email" => id <> "@example.test",
        "password" => "correct horse battery staple"
      })

    repo = Repositories.create(user, %{"name" => "imported"})

    Repo.insert!(%Source{
      repository_id: repo.id,
      url: "https://git.example.com/example/repository.git"
    })

    %{user: user, repo: repo, working: working, remote: remote}
  end

  defp git(directory, args) do
    case System.cmd("git", ["-C", directory | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, _} -> flunk(output)
    end
  end

  defp transfer(repo, user, operation) do
    source =
      Sources.get(repo)
      |> Ecto.Changeset.change(
        job: Ecto.UUID.generate(),
        operation: operation,
        status: "running",
        requested_head: Repositories.head(repo),
        error: nil
      )
      |> Repo.update!()

    Worker.run(repo, user, source, %{username: "git", token: "fixture credential"})
    Sources.get(repo)
  end

  defp upstream(context, path, content) do
    File.write!(Path.join(context.working, path), content)
    git(context.working, ["add", "."])
    git(context.working, ["commit", "--quiet", "-m", "Upstream update"])
    git(context.working, ["push", "--quiet", context.remote, "HEAD:main"])
  end

  defp local(context, path, content) do
    result =
      Changesets.submit(context.repo, context.user, %{
        "base" => Repositories.head(context.repo),
        "message" => "Flurry update",
        "files" => [%{"path" => path, "content" => content}]
      })

    Reviews.approve(context.repo, result.review_id)
    Reviews.land(context.repo, result.review_id)
  end

  test "clone URLs are normalized and unsafe URLs and refs are rejected" do
    assert Remote.parse("https://git.example.com/wess/atlas").url ==
             "https://git.example.com/wess/atlas.git"

    assert Remote.parse("https://git.example.com/group/subgroup/repo/", "feature/test").branch ==
             "feature/test"

    assert Remote.parse("https://git.example.com/~wess/repo").url ==
             "https://git.example.com/~wess/repo.git"

    for url <- [
          "http://git.example.com/wess/atlas",
          "file:///etc/passwd",
          "ssh://git@git.example.com/repo",
          "https://user:secret@git.example.com/wess/atlas",
          "https://127.0.0.1/owner/repo",
          "https://git.example.com.evil.test/owner/repo",
          "https://git.example.com/owner/../repo",
          "https://git.example.com/owner/repo?token=secret",
          "https://git.example.com:444/owner/repo"
        ] do
      assert_raise Flurry.Error, fn -> Remote.parse(url) end
    end

    for branch <- ["--upload-pack=bad", "a..b", "refs//main", "bad.lock", "a\nb", "a@{b}"] do
      assert_raise Flurry.Error, fn -> Remote.branch!(branch) end
    end

    assert_raise Flurry.Error, fn -> Remote.credentials(%{"token" => "bad\r\nheader"}) end
    assert Remote.credentials(%{"username" => "", "token" => ""}).username == "git"
  end

  @tag :job
  test "the import endpoint service runs a background transfer and rejects duplicate jobs",
       context do
    repo =
      Sources.create(context.user, %{
        "url" => "https://git.example.com/example/repository",
        "username" => "",
        "token" => ""
      })

    source = await(repo, 100)
    assert repo.name == "repository"
    assert source.status == "ready"
    assert Repositories.head(repo)
    assert source.message =~ "Imported"

    assert_raise Flurry.Error, fn ->
      Sources.transfer(repo, context.user, "push", %{"head" => "outdated"})
    end
  end

  defp await(repo, remaining) do
    source = Sources.get(repo)

    if source.status == "running" and remaining > 0 do
      receive do
      after
        50 -> :ok
      end

      await(repo, remaining - 1)
    else
      source
    end
  end

  test "initial import creates native files and keeps the source link", context do
    upstream(context, "history.txt", "second revision\n")
    source = transfer(context.repo, context.user, "import")
    assert source.status == "ready"
    assert source.branch == "main"
    assert byte_size(source.commit) == 40
    assert source.modes["script.sh"] == "100755"
    root = Changesets.root(context.repo, Repositories.head(context.repo))
    assert Objects.get(:blob, Tree.entry(root, "readme.md")["hash"]) == "upstream original\n"
    assert length(Changesets.history(context.repo, Repositories.head(context.repo))) == 2
    assert Flurry.Git.View.get(context.repo, Repositories.head(context.repo)).git == source.commit
    assert Reviews.list(context.repo) == []
    refute inspect(Sources.public(source)) =~ "fixture credential"
  end

  test "initial imports reserve the empty repository and transfers cannot overlap", context do
    assert_raise Flurry.Error, ~r/initial source import/, fn ->
      local(context, "local.txt", "local work")
    end

    Sources.get(context.repo) |> Ecto.Changeset.change(status: "running") |> Repo.update!()

    assert_raise Flurry.Error, ~r/already running/, fn ->
      Sources.transfer(context.repo, context.user, "pull", %{})
    end
  end

  test "upstream file-directory replacements remain reviewable and land correctly", context do
    transfer(context.repo, context.user, "import")
    File.rm!(Path.join(context.working, "readme.md"))
    File.mkdir!(Path.join(context.working, "readme.md"))
    upstream(context, "readme.md/child.txt", "nested replacement")
    source = transfer(context.repo, context.user, "pull")
    assert source.status == "ready"
    review = Reviews.get(context.repo, source.review_id)
    assert length(Reviews.detail(context.repo, review).diff) == 2
    Reviews.approve(context.repo, source.review_id)
    Reviews.land(context.repo, source.review_id)
    root = Changesets.root(context.repo, Repositories.head(context.repo))
    assert Tree.entry(root, "readme.md")["type"] == "tree"

    assert Objects.get(:blob, Tree.entry(root, "readme.md/child.txt")["hash"]) ==
             "nested replacement"
  end

  test "pull creates a review and advances the shared baseline only after landing", context do
    original = transfer(context.repo, context.user, "import")
    local(context, "local.txt", "local work")
    upstream(context, "readme.md", "upstream new\n")
    source = transfer(context.repo, context.user, "pull")
    assert source.status == "ready"
    assert source.review_id
    assert source.commit == original.commit
    Reviews.approve(context.repo, source.review_id)
    Reviews.land(context.repo, source.review_id)
    final = Sources.get(context.repo)
    assert final.review_id == nil
    assert final.commit != original.commit
    files = Changesets.root(context.repo, Repositories.head(context.repo)) |> Tree.files()
    assert Map.has_key?(files, "local.txt")
    assert Objects.get(:blob, files["readme.md"]) == "upstream new\n"
    pushed = transfer(context.repo, context.user, "push")
    assert pushed.status == "ready"
    assert git(context.remote, ["show", "main:local.txt"]) == "local work"
    assert git(context.remote, ["show", "main:readme.md"]) == "upstream new\n"
  end

  test "push exports the explicitly selected revision when main advances during transfer",
       context do
    transfer(context.repo, context.user, "import")
    local(context, "selected.txt", "selected work")
    selected = Repositories.head(context.repo)

    Application.put_env(:flurry, :git_on_fetch, fn ->
      local(context, "later.txt", "later work")
    end)

    source = transfer(context.repo, context.user, "push")
    assert source.status == "ready"
    assert Repositories.head(context.repo) != selected
    assert git(context.remote, ["show", "main:selected.txt"]) == "selected work"
    assert git(context.remote, ["ls-tree", "main", "later.txt"]) == ""
  end

  test "push creates a child Git commit with landed files and preserves executable modes",
       context do
    original = transfer(context.repo, context.user, "import")
    local(context, "readme.md", "from flurry\n")
    source = transfer(context.repo, context.user, "push")
    assert source.status == "ready"
    assert source.commit != original.commit
    assert git(context.remote, ["rev-parse", "main^"]) |> String.trim() == original.commit
    assert git(context.remote, ["show", "main:readme.md"]) == "from flurry\n"
    assert git(context.remote, ["ls-tree", "main", "script.sh"]) =~ "100755"
    assert git(context.remote, ["log", "-1", "--format=%ae", "main"]) =~ "@users.flurry.invalid"
    again = transfer(context.repo, context.user, "push")
    assert again.message == "Nothing to push"
    assert again.commit == source.commit
  end

  test "new upstream commits and conflicting edits block push or pull without data loss",
       context do
    original = transfer(context.repo, context.user, "import")
    local(context, "readme.md", "local edit")
    upstream(context, "readme.md", "remote edit")
    failed = transfer(context.repo, context.user, "push")
    assert failed.status == "failed"
    assert failed.error =~ "Pull updates"
    assert failed.commit == original.commit
    failed = transfer(context.repo, context.user, "pull")
    assert failed.status == "failed"
    assert failed.error =~ "readme.md"
    assert git(context.remote, ["show", "main:readme.md"]) == "remote edit"
  end

  test "a racing upstream push is rejected by an exact commit lease", context do
    original = transfer(context.repo, context.user, "import")
    local(context, "local.txt", "local edit")
    Application.put_env(:flurry, :git_race, true)
    failed = transfer(context.repo, context.user, "push")
    assert failed.status == "failed"
    assert failed.commit == original.commit
    assert git(context.remote, ["show", "main:race.txt"]) == "racing upstream change"
    assert git(context.remote, ["ls-tree", "main", "local.txt"]) == ""
  end

  test "a push accepted before a connection failure is safely confirmed on retry", context do
    transfer(context.repo, context.user, "import")
    local(context, "local.txt", "local edit")
    Application.put_env(:flurry, :git_after_push, true)
    failed = transfer(context.repo, context.user, "push")
    assert failed.status == "failed"
    assert failed.push_commit
    Application.delete_env(:flurry, :git_after_push)
    recovered = transfer(context.repo, context.user, "push")
    assert recovered.status == "ready"
    assert recovered.commit == failed.push_commit
    assert recovered.push_commit == nil
    assert git(context.remote, ["rev-list", "--count", "main"]) |> String.trim() == "2"
  end
end
