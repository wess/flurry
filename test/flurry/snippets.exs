defmodule Flurry.SnippetsTest do
  use ExUnit.Case, async: false
  alias Flurry.{Auth, Repo}
  alias Flurry.Engine.Snippets

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    owner = user("Owner")
    reader = user("Reader")
    %{owner: owner, reader: reader}
  end

  test "public snippets retain multi-file revisions, raw files, stars, and forks", ctx do
    snippet =
      Snippets.create(ctx.owner, %{
        "title" => "Request verifier",
        "description" => "A small authenticated request.",
        "visibility" => "public",
        "files" => [
          %{"name" => "request.ts", "content" => "export const verify = () => true;\n"},
          %{"name" => "readme.md", "content" => "# Request verifier\n"}
        ]
      })

    assert snippet.version == 1
    assert Enum.map(snippet.files, & &1.name) == ["readme.md", "request.ts"]
    assert [listed] = Snippets.list(nil)
    assert listed.slug == snippet.slug

    assert {"request.ts", "export const verify = () => true;\n"} =
             Snippets.raw(nil, snippet.slug, "request.ts")

    assert %{stars: 1, starred: true} = Snippets.star(ctx.reader, snippet.slug, true)
    assert Snippets.get(ctx.reader, snippet.slug).starred
    assert %{stars: 0, starred: false} = Snippets.star(ctx.reader, snippet.slug, false)

    updated =
      Snippets.update(ctx.owner, snippet.slug, %{
        "version" => 1,
        "message" => "Return the verified subject",
        "files" => [
          %{"name" => "request.ts", "content" => "export const verify = (id: string) => id;\n"}
        ]
      })

    assert updated.version == 2
    assert Enum.map(updated.revisions, & &1.version) == [2, 1]
    assert Snippets.get(nil, snippet.slug, 1).files |> length() == 2

    fork = Snippets.fork(ctx.reader, snippet.slug)
    assert fork.forked_from == snippet.slug
    assert fork.visibility == "unlisted"
    assert hd(fork.files).content == "export const verify = (id: string) => id;\n"
  end

  test "unlisted snippets require the link and private snippets require ownership", ctx do
    unlisted = create(ctx.owner, "unlisted")
    private = create(ctx.owner, "private")

    assert Snippets.get(nil, unlisted.slug).id == unlisted.id
    refute Enum.any?(Snippets.list(nil), &(&1.id == unlisted.id))

    assert_raise Flurry.Error, ~r/not found/, fn -> Snippets.get(ctx.reader, private.slug) end
    assert Snippets.get(ctx.owner, private.slug).id == private.id
    assert Enum.any?(Snippets.list(ctx.owner, %{"mine" => "true"}), &(&1.id == private.id))
  end

  test "snippet revisions cannot be rewritten", ctx do
    snippet = create(ctx.owner, "public")
    revision = hd(snippet.revisions)

    assert_raise Postgrex.Error, ~r/snippet revisions are immutable/, fn ->
      Repo.query!("UPDATE snippet_revisions SET message = 'rewritten' WHERE id = $1", [
        Ecto.UUID.dump!(revision.id)
      ])
    end
  end

  test "login accepts a username or an email", ctx do
    assert elem(
             Auth.login(%{
               "login" => ctx.owner.username,
               "password" => "correct horse battery staple"
             }),
             0
           ).id == ctx.owner.id

    assert elem(
             Auth.login(%{
               "login" => ctx.owner.email,
               "password" => "correct horse battery staple"
             }),
             0
           ).id == ctx.owner.id
  end

  defp create(user, visibility) do
    Snippets.create(user, %{
      "title" => "#{visibility} example",
      "visibility" => visibility,
      "files" => [%{"name" => "example.ex", "content" => "IO.puts(\"hello\")\n"}]
    })
  end

  defp user(label) do
    value = "s" <> (Ecto.UUID.generate() |> String.replace("-", ""))

    {user, _} =
      Auth.signup(%{
        "name" => label,
        "username" => value,
        "email" => value <> "@example.test",
        "password" => "correct horse battery staple"
      })

    user
  end
end
