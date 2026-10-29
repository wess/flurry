defmodule Flurry.Engine.Trace do
  alias Flurry.{Error, Store.Tree}
  alias Flurry.Engine.Changesets

  def compare(repository, base, head) do
    before = Changesets.root(repository, base)
    target = Changesets.root(repository, head)

    files =
      Changesets.delta(before, target)
      |> Enum.sort()
      |> Enum.map(fn {path, hash} ->
        old = blob(before, path)
        previous = if old, do: Changesets.contents(old["hash"], true), else: nil
        next = if hash, do: Changesets.contents(hash, true), else: nil

        %{
          path: path,
          before: previous,
          after: next,
          kind: kind(old, hash)
        }
      end)

    %{base: base, head: head, files: files}
  end

  def path_history(repository, revision, path) do
    path = Tree.path!(path)

    changesets =
      repository
      |> Changesets.history(revision)
      |> Enum.filter(fn change ->
        Changesets.get(repository, change.id).changes |> Map.has_key?(path)
      end)

    %{revision: revision, path: path, changesets: changesets}
  end

  def blame(repository, revision, path) do
    path = Tree.path!(path)
    root = Changesets.root(repository, revision)
    entry = blob(root, path) || Error.fail("File not found", 404)
    content = Changesets.contents(entry["hash"])

    if content.encoding != "utf8", do: Error.fail("Binary files cannot be blamed", 422)

    lines =
      repository
      |> Changesets.history(revision)
      |> Enum.reverse()
      |> Enum.reduce([], fn public, attributed ->
        change = Changesets.get(repository, public.id)

        if Map.has_key?(change.changes, path) do
          next =
            repository
            |> Changesets.root(change.id)
            |> blob(path)
            |> case do
              nil -> []
              value -> Changesets.contents(value["hash"]).content |> String.split("\n")
            end

          attribute(attributed, next, public)
        else
          attributed
        end
      end)
      |> Enum.with_index(1)
      |> Enum.map(fn {%{text: text, change: change}, line} ->
        %{line: line, text: text, changeset: change}
      end)

    %{revision: revision, path: path, hash: entry["hash"], lines: lines}
  end

  defp attribute(previous, next, change) do
    old = Enum.map(previous, & &1.text)

    List.myers_difference(old, next)
    |> Enum.reduce({previous, []}, fn
      {:eq, lines}, {remaining, result} ->
        {kept, rest} = Enum.split(remaining, length(lines))
        {rest, result ++ kept}

      {:del, lines}, {remaining, result} ->
        {Enum.drop(remaining, length(lines)), result}

      {:ins, lines}, {remaining, result} ->
        {remaining, result ++ Enum.map(lines, &%{text: &1, change: change})}
    end)
    |> elem(1)
  end

  defp blob(root, path) do
    case Tree.entry(root, path) do
      %{"type" => "blob"} = entry -> entry
      _ -> nil
    end
  end

  defp kind(_, nil), do: "deleted"
  defp kind(nil, _), do: "added"
  defp kind(_, _), do: "modified"
end
