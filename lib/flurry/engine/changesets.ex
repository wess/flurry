defmodule Flurry.Engine.Changesets do
  import Ecto.Query
  alias Flurry.{Auth, Error, Repo}
  alias Flurry.Schema.{Changeset, Review, SubmissionReceipt, User}
  alias Flurry.Store.{Objects, Tree}
  alias Flurry.Engine.{Automation, Repositories, ReviewFindings}

  def get(repository, id) do
    Objects.validate!(id)

    Repo.one(from(c in Changeset, where: c.id == ^id and c.repository_id == ^repository.id)) ||
      Error.fail("Changeset not found", 404)
  end

  def resolve(repository, nil), do: Repositories.head(repository)
  def resolve(repository, "main"), do: Repositories.head(repository)
  def resolve(repository, id), do: get(repository, id).id

  def root(_repository, nil), do: Tree.empty()

  def root(repository, id) do
    changeset = get(repository, id)

    case Repo.one(from(m in "manifests", where: m.changeset_id == ^id, select: m.root)) do
      nil ->
        root = root(repository, changeset.parent_id) |> Tree.apply(changeset.changes)
        manifest(id, root)
        root

      root ->
        root
    end
  end

  def submit(repository, user, attrs) do
    if Repo.exists?(
         from(s in Flurry.Schema.Source,
           where: s.repository_id == ^repository.id and is_nil(s.commit)
         )
       ),
       do: Error.fail("Complete the initial source import before submitting changes", 409)

    unless Map.has_key?(attrs, "base"),
      do: Error.fail("An explicit base changeset is required; use null for an empty repository")

    base = attrs["base"]
    if base, do: get(repository, base)
    message = Auth.text!(attrs["message"], "Change message", 2000)
    key = idempotency_key(attrs["idempotency_key"])
    automation = Automation.submission(attrs["automation"])
    previous = root(repository, base)

    changes =
      prepare(
        attrs["files"],
        previous,
        Flurry.Quota.file_limit(Repo.get!(User, repository.owner_id))
      )

    current = Tree.apply(previous, changes) |> Tree.portable!()
    files = Enum.sort(changes) |> Enum.map(fn {path, hash} -> [path, hash] end)

    fingerprint_data =
      if automation,
        do: ["flurry.submission.v2", base, message, files, automation],
        else: [base, message, files]

    fingerprint = Objects.digest(Jason.encode!(fingerprint_data))
    signature_digest = signature_digest(repository.id, base, nil, message, changes)

    verified =
      Flurry.Engine.Keys.verify_signature(
        user,
        signature_digest,
        attrs["signature"],
        repository.require_signed_commits
      )

    {:ok, result} =
      Repo.transaction(fn ->
        Repositories.lock(repository)
        Repositories.writable!(repository)

        receipt =
          if key do
            Repo.one(
              from(r in SubmissionReceipt,
                where:
                  r.repository_id == ^repository.id and r.user_id == ^user.id and r.key == ^key
              )
            )
          end

        if receipt do
          if receipt.fingerprint != fingerprint,
            do: Error.fail("This idempotency key was already used for another submission", 409)

          changeset = get(repository, receipt.changeset_id)
          %{changeset: public(changeset), review_id: receipt.review_id}
        else
          changeset = insert(repository, user.id, base, nil, message, changes, current)
          Automation.record_submission(repository, user, changeset, automation, key)

          review =
            Repo.insert!(%Review{
              id: Ecto.UUID.generate(),
              repository_id: repository.id,
              changeset_id: changeset.id
            })

          ReviewFindings.automatic(repository, review, user, :review_opened)

          Flurry.Engine.Keys.record_signature(changeset.id, verified)

          if key do
            Repo.insert!(%SubmissionReceipt{
              id: Ecto.UUID.generate(),
              repository_id: repository.id,
              user_id: user.id,
              key: key,
              fingerprint: fingerprint,
              changeset_id: changeset.id,
              review_id: review.id
            })
          end

          Flurry.Audit.record(user, "changeset.submit", repository, %{changeset: changeset.id})

          Flurry.Engine.Webhooks.emit(repository, "changeset.submitted", %{
            changeset: public(changeset),
            review_id: review.id
          })

          %{changeset: public(changeset), review_id: review.id}
        end
      end)

    result
  end

  def insert(repository, author, parent, source, message, changes, root, merge_parent \\ nil) do
    Flurry.Quota.record(repository, changes)
    timestamp = DateTime.utc_now()

    canonical = [
      "flurry.changeset.v1",
      repository.id,
      parent,
      source,
      author,
      message,
      DateTime.to_iso8601(timestamp),
      Enum.sort(changes) |> Enum.map(fn {path, hash} -> [path, hash] end)
    ]

    canonical = if merge_parent, do: ["flurry.merge.v1", canonical, merge_parent], else: canonical
    id = canonical |> Jason.encode!() |> Objects.digest()

    changeset =
      Repo.insert!(%Changeset{
        id: id,
        repository_id: repository.id,
        parent_id: parent,
        merge_parent_id: merge_parent,
        source_id: source,
        author_id: author,
        message: message,
        changes: changes,
        inserted_at: timestamp
      })

    manifest(id, root)
    changeset
  end

  def signature_digest(repository_id, parent, merge_parent, message, changes) do
    files = Enum.sort(changes) |> Enum.map(fn {path, hash} -> [path, hash] end)

    Jason.encode!([
      "flurry.change-signature.v1",
      repository_id,
      parent,
      merge_parent,
      message,
      files
    ])
    |> Objects.digest()
  end

  def history(repository, revision) do
    if revision do
      get(repository, revision)

      %{rows: rows} =
        Repo.query!(
          """
          WITH RECURSIVE history AS (
            SELECT id, parent_id, 0 AS depth FROM changesets WHERE id = $1 AND repository_id = $2
            UNION ALL
            SELECT c.id, c.parent_id, h.depth + 1 FROM changesets c
            JOIN history h ON c.id = h.parent_id WHERE h.depth < 99
          ) SELECT id FROM history ORDER BY depth
          """,
          [revision, Ecto.UUID.dump!(repository.id)]
        )

      Enum.map(rows, fn [id] -> get(repository, id) |> public() end)
    else
      []
    end
  end

  def ancestor?(repository, base, head), do: Flurry.Engine.Graph.ancestor?(repository, base, head)

  def diff(repository, changeset, base_id \\ :parent) do
    before = root(repository, if(base_id == :parent, do: changeset.parent_id, else: base_id))

    changes =
      if base_id == :parent,
        do: changeset.changes,
        else: delta(before, root(repository, changeset.id))

    changes
    |> Enum.sort()
    |> Enum.map(fn {path, hash} ->
      entry = Tree.entry(before, path)
      old = if entry && entry["type"] == "blob", do: entry, else: nil
      previous = if old, do: contents(old["hash"], true), else: nil
      next = if hash, do: contents(hash, true), else: nil

      %{
        path: path,
        before: previous,
        after: next,
        kind:
          cond do
            is_nil(hash) -> "deleted"
            is_nil(old) -> "added"
            true -> "modified"
          end,
        lines: lines(previous, next)
      }
    end)
  end

  def delta(before, next) do
    a = Tree.files(before)
    b = Tree.files(next)

    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Enum.filter(&(a[&1] != b[&1]))
    |> Map.new(&{&1, b[&1]})
  end

  def contents(hash, preview \\ false) do
    data = Objects.get(:blob, hash)
    size = byte_size(data)
    text = String.valid?(data) and not String.contains?(data, <<0>>)
    truncated = preview and size > 20_000

    content =
      cond do
        text and truncated -> String.slice(data, 0, 20_000)
        text -> data
        truncated -> ""
        true -> Base.encode64(data)
      end

    %{
      encoding: if(text, do: "utf8", else: "base64"),
      content: content,
      size: size,
      truncated: truncated
    }
  end

  def public(changeset) do
    author = Repo.get!(User, changeset.author_id)

    %{
      id: changeset.id,
      parent: changeset.parent_id,
      merge_parent: changeset.merge_parent_id,
      source: changeset.source_id,
      author: %{id: author.id, name: author.name},
      message: changeset.message,
      files: map_size(changeset.changes),
      inserted_at: changeset.inserted_at
    }
  end

  defp manifest(id, root),
    do: Repo.insert_all("manifests", [%{changeset_id: id, root: root}], on_conflict: :nothing)

  defp idempotency_key(nil), do: nil

  defp idempotency_key(value) do
    value = Auth.text!(value, "Idempotency key", 200)

    if String.match?(value, ~r/[\x00-\x1f\x7f]/),
      do: Error.fail("Idempotency key contains unsupported characters")

    value
  end

  def prepare(files, previous, limit, allow_empty \\ false, max_files \\ 100) do
    range = if allow_empty, do: 0..max_files, else: 1..max_files

    unless is_list(files) and length(files) in range,
      do: Error.fail("Submit between 1 and #{max_files} files")

    paths =
      Enum.map(files, fn
        %{"path" => path} -> Tree.path!(path)
        _ -> Error.fail("Every file requires a path")
      end)

    if length(Enum.uniq(paths)) != length(paths), do: Error.fail("Duplicate file paths")

    Enum.each(paths, fn path ->
      if Enum.any?(paths, &(&1 != path and String.starts_with?(&1, path <> "/"))),
        do: Error.fail("A change cannot contain a path and its descendant")
    end)

    changes =
      files
      |> Enum.map(fn file ->
        path = file["path"]

        value =
          cond do
            Map.has_key?(file, "content") and is_nil(file["content"]) ->
              nil

            is_binary(file["content"]) ->
              file["content"]

            is_binary(file["base64"]) ->
              case Base.decode64(file["base64"]) do
                {:ok, data} -> data
                _ -> Error.fail("Invalid base64 content")
              end

            true ->
              Error.fail("Every file needs content, base64, or content: null for deletion")
          end

        if value && byte_size(value) > limit,
          do: Error.fail("This file exceeds the instance file-size limit", 413)

        {path, value}
      end)
      |> Task.async_stream(&store_file/1,
        max_concurrency: 8,
        ordered: false,
        timeout: 40_000
      )
      |> Enum.map(fn
        {:ok, change} -> change
        {:exit, {%Flurry.Error{} = error, stack}} -> reraise(error, stack)
        {:exit, _reason} -> Error.fail("Object storage could not persist this file", 503)
      end)
      |> Map.new()

    changes =
      Map.reject(changes, fn {path, hash} ->
        case Tree.entry(previous, path) do
          %{"type" => "blob", "hash" => ^hash} -> true
          _ -> false
        end
      end)

    if map_size(changes) == 0 and not allow_empty, do: Error.fail("There are no file changes")
    changes
  end

  defp store_file({path, nil}), do: {path, nil}
  defp store_file({path, value}), do: {path, Objects.put(:blob, value)}

  defp lines(before, next) do
    if (before && (before.encoding != "utf8" or before.truncated)) ||
         (next && (next.encoding != "utf8" or next.truncated)) do
      nil
    else
      old = if before, do: before.content, else: ""
      new = if next, do: next.content, else: ""

      if byte_size(old) + byte_size(new) > 40_000 or
           length(String.split(old, "\n")) + length(String.split(new, "\n")) > 2000 do
        nil
      else
        List.myers_difference(String.split(old, "\n"), String.split(new, "\n"))
        |> Enum.flat_map(fn {kind, lines} ->
          Enum.map(lines, &%{kind: Atom.to_string(kind), text: &1})
        end)
      end
    end
  end
end
