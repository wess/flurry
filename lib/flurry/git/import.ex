defmodule Flurry.Git.Import do
  alias Flurry.{Error, Git.Command, Git.View}
  alias Flurry.Engine.{Refs, Transfers}
  alias Flurry.Store.Tree

  @zero String.duplicate("0", 40)
  @import_limit 10_000

  def apply(repository, user, directory, update) do
    case String.split(String.trim(update), " ") do
      [old, new, "refs/heads/" <> branch] ->
        options = if first_push?(repository, old), do: import_options(), else: []
        branch(repository, user, directory, old, new, branch, options)

      [old, new, "refs/tags/" <> tag] ->
        tag(repository, user, directory, old, new, tag)

      _ ->
        Error.fail("Push one branch or tag at a time", 409)
    end
  end

  def initial(repository, user, directory, git, branch) do
    branch(repository, user, directory, @zero, git, branch, import_options())
  end

  defp first_push?(repository, @zero) do
    %{branches: branches, tags: tags} = Refs.list(repository)
    branches == [%{name: "main", head: nil}] and tags == [] and View.git_ids(repository) == []
  end

  defp first_push?(_, _), do: false

  defp import_options do
    [
      max_commits: @import_limit,
      max_files: 10_000,
      direct_main: true,
      initial_import: true
    ]
  end

  defp branch(repository, user, directory, old, new, branch, options) do
    validate_git!(old)
    validate_git!(new)
    Refs.name!(branch)

    if new == @zero do
      expected = known!(repository, old)
      Refs.delete_branch(repository, user, branch, expected)
    else
      update_branch(repository, user, directory, old, new, branch, options)
    end
  end

  defp update_branch(repository, user, directory, old, new, branch, options) do
    if old != @zero do
      try do
        Command.run(directory, ["merge-base", "--is-ancestor", old, new], limit: 128)
      rescue
        _ in Error -> Error.fail("Non-fast-forward branch updates are not supported", 409)
      end
    end

    expected = if old == @zero, do: nil, else: known!(repository, old)
    known = View.git_ids(repository)

    limit = options[:max_commits] || 100

    arguments =
      ["rev-list", "--reverse", "--topo-order", "--max-count=#{limit + 1}", new] ++
        if(known == [], do: [], else: ["--not" | known])

    revisions =
      Command.run(directory, arguments, limit: 16_384)
      |> String.split("\n", trim: true)

    if length(revisions) > limit,
      do: Error.fail("Transfer at most #{limit} Git commits at a time", 413)

    {commits, mapping} =
      Enum.map_reduce(revisions, %{}, fn git, mapping ->
        validate_git!(git)
        {commit, native} = commit(repository, user, directory, git, mapping, options)
        {commit, Map.put(mapping, git, native)}
      end)

    head = Map.get(mapping, new) || known!(repository, new)

    result =
      Transfers.push(
        repository,
        user,
        %{
          "request_id" => Ecto.UUID.generate(),
          "branch" => branch,
          "expected" => expected,
          "head" => head,
          "commits" => commits
        },
        options
      )

    if result["protected"] && result["review_id"],
      do:
        Error.fail("Main is protected; the push created a review", 409, %{
          review_id: result["review_id"]
        })

    result
  end

  defp tag(repository, user, directory, old, new, name) do
    validate_git!(old)
    validate_git!(new)
    Refs.name!(name)
    if new == @zero, do: Error.fail("Published tags are immutable", 409)

    kind = Command.run(directory, ["cat-file", "-t", new], limit: 128) |> String.trim()

    {target, git, message} =
      if kind == "tag" do
        raw = Command.run(directory, ["cat-file", "tag", new], limit: 98_304)
        text = if String.valid?(raw), do: raw, else: Error.fail("Tag annotations must be UTF-8")
        [headers, message] = String.split(text, "\n\n", parts: 2)

        target =
          headers
          |> String.split("\n")
          |> Enum.find_value(fn
            "object " <> value -> value
            _ -> nil
          end) || Error.fail("Annotated tag has no target")

        {known!(repository, target), %{"id" => new, "raw" => Base.encode64(raw)},
         String.trim(message)}
      else
        {known!(repository, new), nil, nil}
      end

    Refs.tag(repository, user, %{
      "name" => name,
      "target" => target,
      "git" => git,
      "message" => message
    })
  end

  defp commit(repository, user, directory, git, mapping, options) do
    raw = Command.run(directory, ["cat-file", "commit", git], limit: 98_304)
    unless String.valid?(raw), do: Error.fail("Git commit messages must be UTF-8")
    [headers, message] = String.split(raw, "\n\n", parts: 2)

    parents =
      headers
      |> String.split("\n")
      |> Enum.flat_map(fn
        "parent " <> value -> [value]
        _ -> []
      end)

    if length(parents) > 2, do: Error.fail("Octopus merges are not supported", 409)
    parent = parents |> Enum.at(0) |> native(repository, mapping)
    merge = parents |> Enum.at(1) |> native(repository, mapping)
    previous = if Enum.at(parents, 0), do: tree(directory, Enum.at(parents, 0)), else: %{}
    current = tree(directory, git)

    changes =
      (Map.keys(previous) ++ Map.keys(current))
      |> Enum.uniq()
      |> Enum.filter(&(previous[&1] != current[&1]))
      |> Enum.map(fn path ->
        case current[path] do
          nil ->
            %{"path" => path, "content" => nil}

          entry ->
            data = Command.run(directory, ["cat-file", "blob", entry.git], limit: 104_857_600)
            %{"path" => path, "base64" => Base.encode64(data)}
        end
      end)

    max_files = options[:max_files] || 100

    if length(changes) > max_files,
      do: Error.fail("Each commit may change at most #{max_files} files", 413)

    id = Ecto.UUID.generate()

    entry = %{
      "id" => id,
      "parent" => parent,
      "merge_parent" => merge,
      "message" => String.trim_trailing(message),
      "files" => changes,
      "git" => %{
        "id" => git,
        "raw" => Base.encode64(raw),
        "modes" => Map.new(current, fn {path, value} -> {path, value.mode} end)
      }
    }

    signature = signature(repository, user, entry)
    {if(signature, do: Map.put(entry, "signature", signature), else: entry), id}
  end

  defp signature(%{require_signed_commits: false}, _user, _entry), do: nil

  defp signature(_, _, _),
    do:
      Error.fail(
        "Signed-change policy requires pushes through a signing-aware Flurry client",
        409
      )

  defp tree(directory, git) do
    Command.run(directory, ["ls-tree", "-r", "-z", git], limit: 33_554_432)
    |> :binary.split(<<0>>, [:global])
    |> Enum.reject(&(&1 == ""))
    |> Map.new(fn entry ->
      [metadata, path] = :binary.split(entry, "\t")
      [mode, type, object] = String.split(metadata)
      Tree.path!(path)

      unless type == "blob" and mode in ["100644", "100755"],
        do: Error.fail("Symlinks and submodules are not supported", 409)

      {path, %{git: object, mode: mode}}
    end)
  end

  defp native(nil, _, _), do: nil
  defp native(git, repository, mapping), do: Map.get(mapping, git) || known!(repository, git)

  defp known!(repository, git),
    do: View.native(repository, git) || Error.fail("Push references unknown history", 409)

  defp validate_git!(git) do
    unless is_binary(git) and Regex.match?(~r/\A[0-9a-f]{40}\z/, git),
      do: Error.fail("Invalid Git object identifier")
  end
end
