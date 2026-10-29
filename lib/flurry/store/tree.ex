defmodule Flurry.Store.Tree do
  alias Flurry.{Error, Store.Objects}

  def empty, do: write(%{})

  def read(hash) do
    hash
    |> then(&Objects.get(:tree, &1))
    |> Jason.decode!()
    |> Map.new(fn [name, type, id] -> {name, %{"type" => type, "hash" => id}} end)
  end

  def write(entries) do
    entries
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, entry} -> [name, entry["type"], entry["hash"]] end)
    |> Jason.encode!()
    |> then(&Objects.put(:tree, &1))
  end

  def apply(root, changes) do
    changes
    |> Enum.sort_by(fn {path, hash} ->
      {not is_nil(hash), -length(String.split(path, "/")), path}
    end)
    |> Enum.reduce(files(root), &apply_file/2)
    |> from_files()
  end

  def entry(root, ""), do: %{"type" => "tree", "hash" => root}
  def entry(root, path), do: lookup(root, String.split(path, "/"))

  def list(root, path \\ "") do
    case entry(root, path) do
      %{"type" => "tree", "hash" => hash} ->
        read(hash)
        |> Enum.map(fn {name, entry} -> Map.put(entry, "name", name) end)
        |> Enum.sort_by(fn entry -> {entry["type"] != "tree", entry["name"]} end)

      nil ->
        Error.fail("Directory not found", 404)

      _ ->
        Error.fail("Path is a file")
    end
  end

  def path!(path) do
    unless is_binary(path) and byte_size(path) in 1..1024 and String.valid?(path) and
             not String.contains?(path, ["\\", <<0>>]) and
             length(String.split(path, "/")) <= 64 and
             Enum.all?(
               String.split(path, "/"),
               &portable_part?/1
             ),
           do: Error.fail("Invalid repository path")

    path
  end

  def portable!(root) do
    root
    |> files()
    |> Enum.reduce(%{}, fn {path, _}, seen ->
      path!(path)

      path
      |> String.split("/")
      |> Enum.scan("", fn part, prefix ->
        if prefix == "", do: part, else: prefix <> "/" <> part
      end)
      |> Enum.reduce(seen, fn name, names ->
        folded = name |> String.normalize(:nfc) |> String.downcase()

        case names do
          %{^folded => ^name} -> names
          %{^folded => _} -> Error.fail("Repository paths collide by case or Unicode", 409)
          _ -> Map.put(names, folded, name)
        end
      end)
    end)

    root
  end

  def files(root, prefix \\ "") do
    Enum.reduce(read(root), %{}, fn {name, entry}, files ->
      path = if prefix == "", do: name, else: prefix <> "/" <> name

      if entry["type"] == "tree",
        do: Map.merge(files, files(entry["hash"], path)),
        else: Map.put(files, path, entry["hash"])
    end)
  end

  def from_files(files) do
    files
    |> Enum.reduce(%{}, fn {path, hash}, tree ->
      path!(path)
      put_in(tree, Enum.map(String.split(path, "/"), &Access.key(&1, %{})), hash)
    end)
    |> build()
    |> portable!()
  end

  defp portable_part?(part) do
    lower = String.downcase(part)
    stem = lower |> String.split(".", parts: 2) |> hd()

    part not in ["", ".", ".."] and byte_size(part) <= 255 and
      not String.ends_with?(part, [".", " "]) and
      not Regex.match?(~r/[\x00-\x1f\x7f<>:"|?*\x{202a}-\x{202e}\x{2066}-\x{2069}]/u, part) and
      lower not in [".git", ".flurry"] and stem not in ["con", "prn", "aux", "nul"] and
      not Regex.match?(~r/\A(?:com|lpt)[0-9]\z/, stem)
  end

  defp build(tree) do
    tree
    |> Map.new(fn {name, value} ->
      if is_map(value),
        do: {name, %{"type" => "tree", "hash" => build(value)}},
        else: {name, %{"type" => "blob", "hash" => value}}
    end)
    |> write()
  end

  defp lookup(root, [name]), do: Map.get(read(root), name)

  defp lookup(root, [name | rest]) do
    case Map.get(read(root), name) do
      %{"type" => "tree", "hash" => hash} -> lookup(hash, rest)
      _ -> nil
    end
  end

  defp apply_file({path, nil}, files) do
    cond do
      Map.has_key?(files, path) ->
        Map.delete(files, path)

      Enum.any?(Map.keys(files), &String.starts_with?(&1, path <> "/")) ->
        Error.fail("A directory occupies this path", 409, %{path: path})

      true ->
        Error.fail("Cannot delete a missing file")
    end
  end

  defp apply_file({path, hash}, files) do
    cond do
      Enum.any?(Map.keys(files), &String.starts_with?(&1, path <> "/")) ->
        Error.fail("A directory occupies this path", 409, %{path: path})

      Enum.any?(parent_paths(path), &Map.has_key?(files, &1)) ->
        Error.fail("A file occupies a parent directory", 409, %{path: path})

      true ->
        Map.put(files, path, hash)
    end
  end

  defp parent_paths(path) do
    path
    |> String.split("/")
    |> Enum.drop(-1)
    |> Enum.scan(&(&2 <> "/" <> &1))
  end
end
