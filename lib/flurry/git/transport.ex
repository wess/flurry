defmodule Flurry.Git.Transport do
  alias Flurry.{Error, Store.Objects, Store.Tree}
  alias Flurry.Git.{Command, Remote}

  def fetch(source, credentials, directory) do
    remote = source.url |> Remote.parse(source.branch) |> Remote.connect()
    Command.run(directory, ["init", "--bare", "--quiet", "--template=", "."])
    branch = remote.branch || default_branch(directory, remote, credentials)

    Command.run(
      directory,
      ["fetch", "--quiet", "--no-tags", "--", remote.url, "refs/heads/" <> branch],
      remote: remote,
      credentials: credentials
    )

    repository = Flurry.Repo.get!(Flurry.Schema.Repository, source.repository_id)
    owner = Flurry.Repo.get!(Flurry.Schema.User, repository.owner_id)

    snapshot(directory, branch, Flurry.Quota.file_limit(owner))
    |> Map.put(:full_history, true)
  end

  def snapshot(directory, branch, file_limit \\ 1_048_576) do
    commit =
      Command.run(directory, ["rev-parse", "--verify", "FETCH_HEAD^{commit}"]) |> String.trim()

    unless Regex.match?(~r/\A[0-9a-f]{40}\z/, commit),
      do: Error.fail("Unsupported Git object format")

    entries =
      Command.run(directory, ["ls-tree", "-r", "-l", "-z", commit])
      |> :binary.split(<<0>>, [:global])
      |> Enum.reject(&(&1 == ""))

    if length(entries) > 10_000,
      do: Error.fail("Imports currently support at most 10,000 files", 413)

    {files, modes, _size} =
      Enum.reduce(entries, {%{}, %{}, 0}, fn entry, {files, modes, total} ->
        [metadata, path] = :binary.split(entry, "\t")
        [mode, type, object, size] = String.split(metadata)
        Tree.path!(path)

        unless type == "blob" and mode in ["100644", "100755"],
          do:
            Error.fail("Symlinks and submodules are not supported yet; unsupported path: #{path}")

        size = String.to_integer(size)

        if size > file_limit,
          do: Error.fail("Import file exceeds the instance file-size limit: #{path}", 413)

        if total + size > 134_217_728, do: Error.fail("The imported branch exceeds 128 MiB", 413)
        data = Command.run(directory, ["cat-file", "blob", object], limit: file_limit)
        if byte_size(data) != size, do: Error.fail("Git object size mismatch", 500)
        {Map.put(files, path, Objects.put(:blob, data)), Map.put(modes, path, mode), total + size}
      end)

    %{commit: commit, branch: branch, root: Tree.from_files(files), modes: modes, files: files}
  end

  def push(source, credentials, directory, commit) do
    remote = source.url |> Remote.parse(source.branch) |> Remote.connect()

    Command.run(
      directory,
      [
        "push",
        "--quiet",
        "--no-verify",
        "--force-with-lease=refs/heads/#{source.branch}:#{source.commit}",
        "--",
        remote.url,
        "#{commit}:refs/heads/#{source.branch}"
      ],
      remote: remote,
      credentials: credentials
    )
  end

  defp default_branch(directory, remote, credentials) do
    output =
      Command.run(directory, ["ls-remote", "--symref", "--", remote.url, "HEAD"],
        remote: remote,
        credentials: credentials
      )

    case Regex.run(~r/^ref: refs\/heads\/([^\t\r\n]+)\tHEAD$/m, output) do
      [_, branch] ->
        Remote.branch!(branch)

      _ ->
        Error.fail(
          "The repository is empty or its default branch could not be detected; enter a branch explicitly"
        )
    end
  end
end
