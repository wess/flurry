defmodule Flurry.Git.View do
  import Ecto.Query
  alias Flurry.{Repo, Error, Store.Tree, Store.Objects}
  alias Flurry.Engine.Changesets

  def get(repository, id), do: get(repository, id, 0)
  defp get(_, nil, _), do: nil

  defp get(repository, id, depth) do
    if depth > 512,
      do: Error.fail("Git export needs a checkpoint: more than 512 uncached ancestors", 413)

    change = Changesets.get(repository, id)
    lookup(id) || generate(repository, change, depth)
  end

  defp lookup(id),
    do:
      Repo.one(
        from(c in "gitcommits",
          where: c.native == ^id,
          select: %{native: c.native, git: c.git, raw: c.raw, modes: c.modes}
        )
      )

  defp generate(repository, change, depth) do
    parent = get(repository, change.parent_id, depth + 1)
    second = get(repository, change.merge_parent_id, depth + 1)
    files = Tree.files(Changesets.root(repository, change.id))

    modes =
      Map.new(files, fn {path, _} ->
        {path, (parent && parent.modes[path]) || (second && second.modes[path]) || "100644"}
      end)

    {tree, _, _} = tree(files, modes)
    author = Repo.get!(Flurry.Schema.User, change.author_id)
    name = String.replace(author.name, ["\n", "\r", "<", ">", <<0>>], " ")

    identity =
      "#{name} <#{author.id}@users.flurry.invalid> #{DateTime.to_unix(change.inserted_at)} +0000"

    parents = for record <- [parent, second], record, do: "parent #{record.git}\n"

    raw =
      IO.iodata_to_binary([
        "tree #{tree}\n",
        parents,
        "author #{identity}\ncommitter #{identity}\n\n",
        String.replace(change.message, <<0>>, "\\0"),
        "\n\nFlurry-Revision: #{change.id}\n"
      ])

    persist(repository, change.id, raw, modes)
  end

  def attach(_, _, nil), do: :ok

  def attach(repository, change, attrs) when is_map(attrs) do
    encoded = attrs["raw"]

    unless is_binary(encoded) and byte_size(encoded) <= 98_304,
      do: Error.fail("Git commit metadata is too large")

    raw =
      case Base.decode64(encoded) do
        {:ok, raw} -> raw
        _ -> Error.fail("Invalid Git metadata")
      end

    unless object_id("commit", raw) == attrs["id"], do: Error.fail("Git commit identity mismatch")
    files = Tree.files(Changesets.root(repository, change.id))
    modes = attrs["modes"]

    unless is_map(modes) and Enum.sort(Map.keys(modes)) == Enum.sort(Map.keys(files)) and
             Enum.all?(modes, fn {_, mode} -> mode in ["100644", "100755"] end),
           do: Error.fail("Invalid Git file modes")

    {tree, _, _} = tree(files, modes)
    headers = raw |> :binary.split("\n\n") |> hd() |> String.split("\n")
    trees = for "tree " <> value <- headers, do: value
    parents = for "parent " <> value <- headers, do: value

    expected =
      for id <- [change.parent_id, change.merge_parent_id], id, do: get(repository, id).git

    unless trees == [tree] and parents == expected,
      do: Error.fail("Git tree or parent mapping does not match Flurry history")

    persist(repository, change.id, raw, modes)
  end

  def attach(_, _, _), do: Error.fail("Invalid Git metadata")

  defp persist(repository, id, raw, modes) do
    git = object_id("commit", raw)

    Repo.insert_all(
      "gitcommits",
      [
        %{
          native: id,
          repository_id: Ecto.UUID.dump!(repository.id),
          git: git,
          raw: raw,
          modes: modes
        }
      ],
      on_conflict: :nothing
    )

    lookup(id)
  end

  def public(repository, id) do
    record = get(repository, id)
    change = Changesets.get(repository, id)
    files = Tree.files(Changesets.root(repository, id))
    {_, trees, blobs} = tree(files, record.modes)

    %{
      native: id,
      git: record.git,
      raw: Base.encode64(record.raw),
      parents: Enum.reject([change.parent_id, change.merge_parent_id], &is_nil/1),
      trees: Enum.map(trees, fn {git, data} -> %{git: git, raw: Base.encode64(data)} end),
      files:
        Enum.map(files, fn {path, hash} ->
          %{path: path, hash: hash, git: blobs[hash], mode: record.modes[path]}
        end)
    }
  end

  def native(repository, git) do
    Repo.one(
      from(c in "gitcommits",
        where: c.repository_id == ^Ecto.UUID.dump!(repository.id) and c.git == ^git,
        select: c.native
      )
    )
  end

  def git_ids(repository) do
    Repo.all(
      from(c in "gitcommits",
        where: c.repository_id == ^Ecto.UUID.dump!(repository.id),
        select: c.git
      )
    )
  end

  defp tree(files, modes) do
    if map_size(files) > 100_000, do: Error.fail("Git view supports at most 100,000 files", 413)
    blobs = files |> Map.values() |> Enum.uniq() |> Map.new(&{&1, blob(&1)})

    nested =
      Enum.reduce(files, %{}, fn {path, hash}, tree ->
        put_in(
          tree,
          Enum.map(String.split(path, "/"), &Access.key(&1, %{})),
          {modes[path], blobs[hash]}
        )
      end)

    {root, trees} = encode_tree(nested)
    {root, trees, blobs}
  end

  defp encode_tree(entries) do
    {payload, children} =
      entries
      |> Enum.sort_by(fn {name, value} -> name <> if(is_map(value), do: "/", else: "") end)
      |> Enum.map_reduce([], fn {name, value}, acc ->
        {mode, id, children} =
          if is_map(value) do
            {id, descendants} = encode_tree(value)
            {"40000", id, descendants}
          else
            {mode, id} = value
            {mode, id, []}
          end

        {[mode, " ", name, <<0>>, Base.decode16!(id, case: :lower)], children ++ acc}
      end)

    data = IO.iodata_to_binary(payload)
    id = object_id("tree", data)
    {id, children ++ [{id, data}]}
  end

  defp blob(hash) do
    Repo.one(from(b in "gitblobs", where: b.native == ^hash, select: b.git)) ||
      (
        git = object_id("blob", Objects.get(:blob, hash))
        Repo.insert_all("gitblobs", [%{native: hash, git: git}], on_conflict: :nothing)
        git
      )
  end

  def object_id(type, data),
    do:
      :crypto.hash(:sha, [type, " ", Integer.to_string(byte_size(data)), <<0>>, data])
      |> Base.encode16(case: :lower)
end
