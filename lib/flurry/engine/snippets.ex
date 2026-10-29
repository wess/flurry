defmodule Flurry.Engine.Snippets do
  import Ecto.Query
  alias Flurry.{Auth, Error, Repo}
  alias Flurry.Schema.{Snippet, SnippetFile, SnippetRevision, SnippetStar, User}
  alias Flurry.Store.Tree

  @visibilities ["public", "unlisted", "private"]
  @file_limit 262_144
  @total_limit 1_048_576

  def list(user, params \\ %{}) do
    mine = params["mine"] == "true"
    query = text(params["query"], 200)

    base =
      from(s in Snippet,
        join: u in User,
        on: u.id == s.author_id,
        order_by: [desc: s.updated_at, desc: s.id],
        limit: 100,
        select: {s, u}
      )

    base =
      cond do
        mine && user -> from([s, _u] in base, where: s.author_id == ^user.id)
        mine -> from([s, _u] in base, where: false)
        user -> from([s, _u] in base, where: s.visibility == "public" or s.author_id == ^user.id)
        true -> from([s, _u] in base, where: s.visibility == "public")
      end

    base =
      if query == "" do
        base
      else
        term = "%#{escape_like(query)}%"

        from([s, _u] in base,
          where: ilike(s.title, ^term) or ilike(s.description, ^term) or ilike(s.slug, ^term)
        )
      end

    Repo.all(base)
    |> Enum.map(fn {snippet, author} -> summary(snippet, author, user) end)
  end

  def get(user, slug, version \\ nil) do
    {snippet, author} = record!(user, slug)
    revision = revision!(snippet, version)

    summary(snippet, author, user)
    |> Map.merge(%{
      files: files(revision.id),
      revision: revision_public(revision),
      revisions: revisions(snippet.id),
      forked_from: forked_from(snippet)
    })
  end

  def create(user, attrs) do
    prepared = prepare_files(attrs["files"])

    {:ok, snippet} =
      Repo.transaction(fn ->
        snippet =
          %Snippet{}
          |> Ecto.Changeset.change(
            id: Ecto.UUID.generate(),
            author_id: user.id,
            slug: slug(),
            title: Auth.text!(attrs["title"], "Snippet title", 200),
            description: text(attrs["description"], 2_000),
            visibility: visibility(attrs["visibility"] || "unlisted")
          )
          |> Repo.insert!()

        insert_revision(snippet, user, 1, attrs["message"], prepared)
        Flurry.Audit.record(user, "snippet.create", nil, %{snippet: snippet.id})
        snippet
      end)

    get(user, snippet.slug)
  end

  def update(user, slug, attrs) do
    {:ok, snippet} =
      Repo.transaction(fn ->
        {snippet, _author} = record!(user, slug, true)
        expected = integer(attrs["version"], "Snippet version")

        unless expected == snippet.version,
          do: Error.fail("This snippet changed; reload before saving", 409)

        changed_files = Map.has_key?(attrs, "files")
        next_version = if changed_files, do: snippet.version + 1, else: snippet.version

        snippet =
          snippet
          |> Ecto.Changeset.change(
            title:
              if(Map.has_key?(attrs, "title"),
                do: Auth.text!(attrs["title"], "Snippet title", 200),
                else: snippet.title
              ),
            description:
              if(Map.has_key?(attrs, "description"),
                do: text(attrs["description"], 2_000),
                else: snippet.description
              ),
            visibility:
              if(Map.has_key?(attrs, "visibility"),
                do: visibility(attrs["visibility"]),
                else: snippet.visibility
              ),
            version: next_version
          )
          |> Repo.update!()

        if changed_files do
          insert_revision(
            snippet,
            user,
            next_version,
            attrs["message"],
            prepare_files(attrs["files"])
          )
        end

        Flurry.Audit.record(user, "snippet.update", nil, %{
          snippet: snippet.id,
          version: next_version
        })

        snippet
      end)

    get(user, snippet.slug)
  end

  def delete(user, slug) do
    {snippet, _author} = record!(user, slug, true)
    Repo.delete!(snippet)
    Flurry.Audit.record(user, "snippet.delete", nil, %{snippet: snippet.id})
    :ok
  end

  def fork(user, slug) do
    source = get(user, slug)

    fork =
      create(user, %{
        "title" => source.title,
        "description" => source.description,
        "visibility" => "unlisted",
        "message" => "Forked from #{source.author.username}/#{source.slug}",
        "files" => Enum.map(source.files, &%{"name" => &1.name, "content" => &1.content})
      })

    Repo.get!(Snippet, fork.id)
    |> Ecto.Changeset.change(forked_from_id: source.id)
    |> Repo.update!()

    get(user, fork.slug)
  end

  def star(user, slug, enabled) when is_boolean(enabled) do
    {snippet, _author} = record!(user, slug)

    if enabled do
      Repo.insert_all(
        SnippetStar,
        [%{snippet_id: snippet.id, user_id: user.id, inserted_at: DateTime.utc_now()}],
        on_conflict: :nothing
      )
    else
      Repo.delete_all(
        from(s in SnippetStar, where: s.snippet_id == ^snippet.id and s.user_id == ^user.id)
      )
    end

    %{starred: enabled, stars: star_count(snippet.id)}
  end

  def raw(user, slug, path, version \\ nil) do
    {snippet, _author} = record!(user, slug)
    revision = revision!(snippet, version)
    name = Tree.path!(path)

    file =
      Repo.get_by(SnippetFile, revision_id: revision.id, name: name) ||
        Error.fail("Snippet file not found", 404)

    {file.name, file.content}
  end

  defp record!(user, slug, owner \\ false) do
    unless is_binary(slug) and Regex.match?(~r/\A[a-zA-Z0-9_-]{8,24}\z/, slug),
      do: Error.fail("Snippet not found", 404)

    result =
      Repo.one(
        from(s in Snippet,
          join: u in User,
          on: u.id == s.author_id,
          where: s.slug == ^slug,
          select: {s, u}
        )
      ) || Error.fail("Snippet not found", 404)

    {snippet, _author} = result
    allowed = not is_nil(user) and snippet.author_id == user.id

    unless allowed or (not owner and snippet.visibility in ["public", "unlisted"]),
      do: Error.fail("Snippet not found", 404)

    result
  end

  defp revision!(snippet, nil),
    do: Repo.get_by!(SnippetRevision, snippet_id: snippet.id, version: snippet.version)

  defp revision!(snippet, value) do
    version = integer(value, "Snippet version")

    Repo.get_by(SnippetRevision, snippet_id: snippet.id, version: version) ||
      Error.fail("Snippet revision not found", 404)
  end

  defp insert_revision(snippet, user, version, message, files) do
    revision =
      Repo.insert!(%SnippetRevision{
        id: Ecto.UUID.generate(),
        snippet_id: snippet.id,
        author_id: user.id,
        version: version,
        message: text(message, 500)
      })

    now = DateTime.utc_now()

    Repo.insert_all(
      SnippetFile,
      Enum.map(files, fn file ->
        Map.merge(file, %{id: Ecto.UUID.generate(), revision_id: revision.id, inserted_at: now})
      end)
    )
  end

  defp prepare_files(value) when is_list(value) and length(value) in 1..20 do
    files =
      Enum.map(value, fn entry ->
        unless is_map(entry), do: Error.fail("Each snippet file must be an object")
        name = Tree.path!(entry["name"])
        content = entry["content"]

        unless is_binary(content) and String.valid?(content),
          do: Error.fail("Snippet files must contain UTF-8 text")

        bytes = byte_size(content)
        if bytes > @file_limit, do: Error.fail("Snippet files may be at most 256 KiB", 413)
        %{name: name, content: content, bytes: bytes}
      end)

    if Enum.uniq_by(files, & &1.name) != files,
      do: Error.fail("Snippet file names must be unique")

    if Enum.sum(Enum.map(files, & &1.bytes)) > @total_limit,
      do: Error.fail("A snippet may contain at most 1 MiB", 413)

    files
  end

  defp prepare_files(_), do: Error.fail("A snippet needs between 1 and 20 files")

  defp summary(snippet, author, user) do
    %{
      id: snippet.id,
      slug: snippet.slug,
      title: snippet.title,
      description: snippet.description,
      visibility: snippet.visibility,
      version: snippet.version,
      author: Auth.public(author),
      owner: not is_nil(user) and user.id == snippet.author_id,
      starred:
        not is_nil(user) and
          Repo.exists?(
            from(s in SnippetStar, where: s.snippet_id == ^snippet.id and s.user_id == ^user.id)
          ),
      stars: star_count(snippet.id),
      inserted_at: snippet.inserted_at,
      updated_at: snippet.updated_at
    }
  end

  defp files(revision_id) do
    Repo.all(from(f in SnippetFile, where: f.revision_id == ^revision_id, order_by: f.name))
    |> Enum.map(&%{id: &1.id, name: &1.name, content: &1.content, bytes: &1.bytes})
  end

  defp revisions(snippet_id) do
    Repo.all(
      from(r in SnippetRevision,
        join: u in User,
        on: u.id == r.author_id,
        where: r.snippet_id == ^snippet_id,
        order_by: [desc: r.version],
        select: {r, u}
      )
    )
    |> Enum.map(fn {revision, author} ->
      revision_public(revision) |> Map.put(:author, Auth.public(author))
    end)
  end

  defp revision_public(revision),
    do: %{
      id: revision.id,
      version: revision.version,
      message: revision.message,
      inserted_at: revision.inserted_at
    }

  defp forked_from(%Snippet{forked_from_id: nil}), do: nil

  defp forked_from(snippet) do
    Repo.one(from(s in Snippet, where: s.id == ^snippet.forked_from_id, select: s.slug))
  end

  defp star_count(id),
    do: Repo.one(from(s in SnippetStar, where: s.snippet_id == ^id, select: count())) || 0

  defp visibility(value) when value in @visibilities, do: value
  defp visibility(_), do: Error.fail("Choose public, unlisted, or private visibility")

  defp integer(value, _label) when is_integer(value) and value > 0, do: value

  defp integer(value, label) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> Error.fail("#{label} must be a positive integer")
    end
  end

  defp integer(_, label), do: Error.fail("#{label} must be a positive integer")

  defp text(nil, _limit), do: ""

  defp text(value, limit) do
    unless is_binary(value) and String.valid?(value) and byte_size(value) <= limit,
      do: Error.fail("Text must be at most #{limit} bytes")

    String.trim(value)
  end

  defp escape_like(value), do: String.replace(value, ["%", "_"], &"\\#{&1}")

  defp slug do
    Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  end
end
