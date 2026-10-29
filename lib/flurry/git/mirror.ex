defmodule Flurry.Git.Mirror do
  alias Flurry.{Error, Store.Objects}
  alias Flurry.Engine.{Changesets, Refs}
  alias Flurry.Git.{Command, View}

  def with_repository(repository, callback) do
    root = System.tmp_dir!()
    directory = Path.join(root, "flurry-git-" <> random())
    File.mkdir_p!(directory)

    try do
      materialize(repository, directory)
      callback.(directory)
    after
      File.rm_rf(directory)
    end
  end

  def materialize(repository, directory) do
    Command.run(directory, ["init", "--bare", "--quiet", "--template=", "."])
    refs = Refs.list(repository)

    revisions =
      (Enum.map(refs.branches, & &1.head) ++ Enum.map(refs.tags, & &1.target))
      |> Enum.reject(&is_nil/1)
      |> walk(repository, MapSet.new())

    if MapSet.size(revisions) > 10_000,
      do: Error.fail("Smart Git transfer supports at most 10,000 revisions", 413)

    Enum.each(revisions, fn revision -> write_revision(repository, directory, revision) end)

    Enum.each(refs.branches, fn branch ->
      if branch.head do
        git = View.get(repository, branch.head).git
        Command.run(directory, ["update-ref", "refs/heads/" <> branch.name, git])
      end
    end)

    Enum.each(refs.tags, fn tag ->
      target =
        if tag.raw do
          raw = Base.decode64!(tag.raw)
          write_object(directory, "tag", raw, tag.git)
        else
          View.get(repository, tag.target).git
        end

      Command.run(directory, ["update-ref", "refs/tags/" <> tag.name, target])
    end)

    Command.run(directory, ["symbolic-ref", "HEAD", "refs/heads/main"])
    directory
  end

  defp walk([], _repository, seen), do: seen

  defp walk([id | rest], repository, seen) do
    if MapSet.member?(seen, id) do
      walk(rest, repository, seen)
    else
      if MapSet.size(seen) >= 10_000,
        do: Error.fail("Smart Git transfer supports at most 10,000 revisions", 413)

      change = Changesets.get(repository, id)
      parents = Enum.reject([change.parent_id, change.merge_parent_id], &is_nil/1)
      walk(rest ++ parents, repository, MapSet.put(seen, id))
    end
  end

  defp write_revision(repository, directory, revision) do
    view = View.public(repository, revision)

    Enum.each(view.files, fn file ->
      write_object(directory, "blob", Objects.get(:blob, file.hash), file.git)
    end)

    Enum.each(view.trees, fn tree ->
      write_object(directory, "tree", Base.decode64!(tree.raw), tree.git)
    end)

    write_object(directory, "commit", Base.decode64!(view.raw), view.git)
  end

  defp write_object(directory, type, data, expected) do
    actual = View.object_id(type, data)

    unless actual == expected,
      do: Error.fail("Generated Git object failed integrity validation", 500)

    target =
      Path.join([directory, "objects", String.slice(actual, 0, 2), String.slice(actual, 2, 38)])

    unless File.exists?(target) do
      File.mkdir_p!(Path.dirname(target))

      File.write!(target, :zlib.compress("#{type} #{byte_size(data)}\0" <> data), [
        :binary,
        :exclusive
      ])
    end

    actual
  end

  defp random, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
