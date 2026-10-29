defmodule Flurry.EngineTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Flurry.{Auth, Repo, Profiles}
  alias Flurry.Engine.{Repositories, Changesets, Reviews, Symbols, Trace}
  alias Flurry.Store.{Objects, Tree}

  setup tags do
    unless tags[:concurrent], do: Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  defp user do
    id = Ecto.UUID.generate() |> String.replace("-", "")

    {user, _} =
      Auth.signup(%{
        "name" => "Test user",
        "username" => "u" <> id,
        "email" => id <> "@example.test",
        "password" => "correct horse battery staple"
      })

    user
  end

  defp repository(user), do: Repositories.create(user, %{"name" => "sample"})

  defp submit(repo, user, base, files, message \\ "Update files") do
    Changesets.submit(repo, user, %{
      "base" => base,
      "message" => message,
      "files" =>
        Enum.map(files, fn {path, content} -> %{"path" => path, "content" => content} end)
    })
  end

  defp land(repo, submitted) do
    Reviews.approve(repo, submitted.review_id)
    Reviews.land(repo, submitted.review_id).head
  end

  test "content addressing deduplicates blobs and verifies corruption" do
    hash = Objects.put(:blob, "hello\n")
    assert hash == Objects.put(:blob, "hello\n")
    assert Objects.get(:blob, hash) == "hello\n"
    assert hash != Objects.put(:tree, "hello\n")
    assert_raise Flurry.Error, fn -> Objects.get(:blob, "../../etc/passwd") end
    corrupted = Objects.put(:blob, :crypto.strong_rand_bytes(16))

    path =
      Path.join([
        Application.fetch_env!(:flurry, :store),
        String.slice(corrupted, 0, 2),
        corrupted
      ])

    File.write!(path, :zlib.compress("blob\0tampered"))
    assert_raise Flurry.Error, ~r/integrity/, fn -> Objects.get(:blob, corrupted) end
  end

  test "repository creation can land a README, ignore file, and license atomically" do
    user = user()

    repository =
      Repositories.create(user, %{
        "name" => "ready",
        "description" => "Ready to build.",
        "initialize_readme" => true,
        "gitignore_template" => "elixir",
        "license_template" => "mit"
      })

    head = Repositories.head(repository)
    assert is_binary(head)
    files = repository |> Changesets.root(head) |> Tree.files()
    assert Map.keys(files) |> Enum.sort() == [".gitignore", "LICENSE", "README.md"]
    assert Changesets.contents(files["README.md"]).content == "# ready\n\nReady to build.\n"
    assert Changesets.contents(files["LICENSE"]).content =~ "MIT License"

    assert Changesets.history(repository, head) |> hd() |> Map.fetch!(:message) ==
             "Initial commit"

    assert_raise Flurry.Error, ~r/valid ignore template/, fn ->
      Repositories.create(user, %{"name" => "invalid", "gitignore_template" => "unknown"})
    end

    refute Repo.get_by(Flurry.Schema.Repository, owner_id: user.id, name: "invalid")
  end

  test "syntax summaries identify changed declarations without affecting content" do
    summary =
      Symbols.summary(%{
        path: "lib/parser.ex",
        before: %{encoding: "utf8", content: "defmodule Parser do\n  def parse(x), do: x\nend"},
        after: %{encoding: "utf8", content: "defmodule Parser do\n  def parse(x), do: x + 1\nend"},
        lines: [
          %{kind: "eq", text: "defmodule Parser do"},
          %{kind: "del", text: "  def parse(x), do: x"},
          %{kind: "ins", text: "  def parse(x), do: x + 1"},
          %{kind: "eq", text: "end"}
        ]
      })

    assert summary.language == "Elixir"
    assert Enum.any?(summary.changed, &(&1.name == "parse" and &1.change == "modified"))
  end

  test "submissions leave main unchanged and sparse trees preserve old revisions" do
    user = user()
    repo = repository(user)
    first = submit(repo, user, nil, [{"lib/main.ex", "first"}, {"readme.md", "hello"}])
    assert Repositories.head(repo) == nil
    head = land(repo, first)
    old = Changesets.root(repo, head)
    second = submit(repo, user, head, [{"lib/main.ex", "second"}])
    newhead = land(repo, second)
    assert Objects.get(:blob, Tree.entry(old, "lib/main.ex")["hash"]) == "first"

    assert Objects.get(:blob, Tree.entry(Changesets.root(repo, newhead), "lib/main.ex")["hash"]) ==
             "second"

    assert Tree.entry(old, "readme.md") == Tree.entry(Changesets.root(repo, newhead), "readme.md")
    assert length(Changesets.history(repo, newhead)) == 2
  end

  test "submission idempotency returns one immutable change and rejects key reuse" do
    user = user()
    repo = repository(user)

    attrs = %{
      "base" => nil,
      "message" => "Add a file",
      "files" => [%{"path" => "a.txt", "content" => "a"}],
      "idempotency_key" => "submission-1"
    }

    first = Changesets.submit(repo, user, attrs)
    assert Changesets.submit(repo, user, attrs) == first

    assert Repo.aggregate(
             from(c in Flurry.Schema.Changeset, where: c.repository_id == ^repo.id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(r in Flurry.Schema.Review, where: r.repository_id == ^repo.id),
             :count
           ) == 1

    error =
      assert_raise Flurry.Error, fn ->
        Changesets.submit(repo, user, put_in(attrs, ["files", Access.at(0), "content"], "b"))
      end

    assert error.status == 409
  end

  test "disjoint stale changes rebase while conflicting changes cannot advance main" do
    user = user()
    repo = repository(user)
    base = submit(repo, user, nil, [{"a.txt", "a"}, {"b.txt", "b"}]) |> then(&land(repo, &1))
    first = submit(repo, user, base, [{"a.txt", "changed"}])
    second = submit(repo, user, base, [{"b.txt", "changed"}])
    conflict = submit(repo, user, base, [{"a.txt", "other"}])
    firsthead = land(repo, first)
    secondhead = land(repo, second)
    rebased = Changesets.get(repo, secondhead)
    assert rebased.parent_id == firsthead
    assert rebased.source_id == second.changeset.id
    Reviews.approve(repo, conflict.review_id)
    error = assert_raise Flurry.Error, fn -> Reviews.land(repo, conflict.review_id) end
    assert error.status == 409
    assert error.details.paths == ["a.txt"]
    assert Repositories.head(repo) == secondhead
    assert Reviews.get(repo, conflict.review_id).status == "approved"
    assert Reviews.land(repo, second.review_id).head == secondhead
  end

  test "missing manifests are rebuilt from immutable changesets" do
    user = user()
    repo = repository(user)
    first = submit(repo, user, nil, [{"dir/a.txt", "a"}]) |> then(&land(repo, &1))
    second = submit(repo, user, first, [{"dir/b.txt", "b"}]) |> then(&land(repo, &1))
    expected = Changesets.root(repo, second)
    Repo.query!("DELETE FROM manifests")
    assert Changesets.root(repo, second) == expected
  end

  test "compare, path history and blame retain line authorship" do
    user = user()
    repo = repository(user)
    first = submit(repo, user, nil, [{"readme.md", "one\ntwo\n"}]) |> then(&land(repo, &1))

    second =
      submit(repo, user, first, [{"readme.md", "one\nchanged\ntwo\n"}])
      |> then(&land(repo, &1))

    assert %{files: [%{path: "readme.md", kind: "modified"}]} =
             Trace.compare(repo, first, second)

    assert %{changesets: [latest, oldest]} = Trace.path_history(repo, second, "readme.md")
    assert latest.id == second
    assert oldest.id == first

    assert %{lines: lines} = Trace.blame(repo, second, "readme.md")
    assert Enum.map(lines, & &1.text) == ["one", "changed", "two", ""]
    assert Enum.map(lines, & &1.changeset.id) == [first, second, first, first]
  end

  test "approval is required and an unlanded parent is rejected" do
    user = user()
    repo = repository(user)
    first = submit(repo, user, nil, [{"a", "a"}])
    assert_raise Flurry.Error, ~r/Approve/, fn -> Reviews.land(repo, first.review_id) end
    second = submit(repo, user, first.changeset.id, [{"b", "b"}])
    Reviews.approve(repo, second.review_id)
    assert_raise Flurry.Error, ~r/unlanded/, fn -> Reviews.land(repo, second.review_id) end
  end

  test "deletion prunes directories and binary blobs round trip" do
    user = user()
    repo = repository(user)
    first = submit(repo, user, nil, [{"dir/a", "a"}]) |> then(&land(repo, &1))
    second = submit(repo, user, first, [{"dir/a", nil}]) |> then(&land(repo, &1))
    assert Tree.list(Changesets.root(repo, second)) == []
    bytes = <<0, 255, 17>>

    result =
      Changesets.submit(repo, user, %{
        "base" => second,
        "message" => "Binary",
        "files" => [%{"path" => "blob", "base64" => Base.encode64(bytes)}]
      })

    [diff] = Changesets.diff(repo, Changesets.get(repo, result.changeset.id))
    assert diff.after.encoding == "base64"
    assert Base.decode64!(diff.after.content) == bytes
  end

  test "invalid paths, duplicate paths, no-op changes and file-directory collisions are rejected" do
    user = user()
    repo = repository(user)

    for path <- [
          "../secret",
          "/root",
          "a//b",
          "a/./b",
          "a\\b",
          "a\0b",
          ".git/config",
          ".flurry/state",
          "CON",
          "aux.txt",
          "a:b",
          "trailing.",
          "control\u0007"
        ] do
      assert_raise Flurry.Error, fn -> submit(repo, user, nil, [{path, "x"}]) end
    end

    assert_raise Flurry.Error, fn -> submit(repo, user, nil, [{"a", "x"}, {"a", "y"}]) end
    assert_raise Flurry.Error, fn -> submit(repo, user, nil, [{"a", "x"}, {"a/b", "y"}]) end
    assert_raise Flurry.Error, fn -> submit(repo, user, nil, [{"A", "x"}, {"a", "y"}]) end

    assert_raise Flurry.Error, fn ->
      submit(repo, user, nil, [{"caf\u00e9", "x"}, {"cafe\u0301", "y"}])
    end

    base = submit(repo, user, nil, [{"a", "x"}]) |> then(&land(repo, &1))
    assert_raise Flurry.Error, fn -> submit(repo, user, base, [{"a", "x"}]) end
    assert_raise Flurry.Error, fn -> submit(repo, user, base, [{"a/b", "y"}]) end
    assert_raise Flurry.Error, fn -> submit(repo, user, base, [{"missing", nil}]) end

    upper = submit(repo, user, nil, [{"Upper", "x"}]) |> then(&land(repo, &1))
    assert_raise Flurry.Error, fn -> submit(repo, user, upper, [{"upper", "y"}]) end
  end

  test "private repositories and their profile activity cannot leak to another user" do
    owner = user()
    stranger = user()
    private = repository(owner)
    public = Repositories.create(owner, %{"name" => "public", "visibility" => "public"})
    submit(private, owner, nil, [{"secret", "secret"}], "Private title")
    submit(public, owner, nil, [{"readme.md", "hello"}], "Public title")
    assert_raise Flurry.Error, fn -> Repositories.get(stranger, private.id) end
    assert_raise Flurry.Error, fn -> Repositories.get(nil, private.id) end
    assert Repositories.get(nil, public.id).id == public.id
    assert_raise Flurry.Error, fn -> Repositories.get(stranger, public.id, :write) end
    profile = Profiles.get(owner.username, stranger)
    assert Enum.map(profile.repositories, & &1.id) == [public.id]
    assert Enum.map(profile.activity, & &1.message) == ["Public title"]
    refute Map.has_key?(profile, :email)
    assert length(Profiles.get(owner.username, owner).repositories) == 2
  end

  test "profiles validate website schemes and authentication can be revoked" do
    user = user()

    updated =
      Profiles.update(user, %{
        "name" => "Wess",
        "bio" => "Building Flurry",
        "website" => "https://wess.io"
      })

    assert updated.bio == "Building Flurry"

    assert_raise Flurry.Error, fn ->
      Profiles.update(user, %{"name" => "Wess", "website" => "javascript:alert(1)"})
    end

    {_, token} =
      Auth.login(%{"email" => user.email, "password" => "correct horse battery staple"})

    assert Auth.resolve(token).id == user.id
    Auth.revoke(token)
    assert Auth.resolve(token) == nil

    assert_raise Flurry.Error, fn ->
      Auth.login(%{"email" => user.email, "password" => "wrong"})
    end
  end

  test "the database rejects mutations to existing changesets" do
    user = user()
    repo = repository(user)
    result = submit(repo, user, nil, [{"a", "a"}])

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.query!("UPDATE changesets SET message = 'changed' WHERE id = $1", [result.changeset.id])
    end
  end

  @tag :concurrent
  test "concurrent edits to the same file produce exactly one landing" do
    {repo, changes} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        owner = user()
        repo = repository(owner)
        base = submit(repo, owner, nil, [{"shared.txt", "base"}]) |> then(&land(repo, &1))

        changes =
          Enum.map(["left", "right"], fn value ->
            change = submit(repo, owner, base, [{"shared.txt", value}])
            Reviews.approve(repo, change.review_id)
            change
          end)

        {repo, changes}
      end)

    results =
      Task.async_stream(
        changes,
        fn change ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            try do
              {:landed, Reviews.land(repo, change.review_id).head}
            rescue
              error in Flurry.Error -> {:rejected, error.status}
            end
          end)
        end,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:landed, _}, &1)) == 1
    assert Enum.count(results, &match?({:rejected, 409}, &1)) == 1

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert length(Changesets.history(repo, Repositories.head(repo))) == 2
    end)
  end

  @tag :concurrent
  test "independent database connections land concurrent changes without losing files" do
    {owner, repo, changes} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        owner = user()
        repo = repository(owner)
        base = submit(repo, owner, nil, [{"readme.md", "base"}]) |> then(&land(repo, &1))

        changes =
          Enum.map(1..12, fn i ->
            change = submit(repo, owner, base, [{"files/#{i}.txt", "#{i}"}])
            Reviews.approve(repo, change.review_id)
            change
          end)

        {owner, repo, changes}
      end)

    results =
      Task.async_stream(
        changes,
        fn change ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Reviews.land(repo, change.review_id)
          end)
        end,
        max_concurrency: 12,
        timeout: 30_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, %{head: _}}, &1))

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      repo = Repositories.get(owner, repo.id)
      root = Changesets.root(repo, Repositories.head(repo))
      assert length(Tree.list(root, "files")) == 12

      for i <- 1..12,
          do: assert(Objects.get(:blob, Tree.entry(root, "files/#{i}.txt")["hash"]) == "#{i}")
    end)
  end
end
