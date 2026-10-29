defmodule Flurry.Git.Worker do
  import Ecto.Query
  alias Flurry.{Error, Repo, Store.Tree}
  alias Flurry.Schema.{Source, Review}
  alias Flurry.Engine.{Changesets, Repositories, ReviewFindings}
  alias Flurry.Git.Export

  def run(repository, user, source, credentials) do
    directory = Path.join(System.tmp_dir!(), "flurry" <> String.replace(source.job, "-", ""))

    try do
      File.mkdir_p!(directory)
      File.chmod!(directory, 0o700)
      adapter = Application.get_env(:flurry, :git_transport, Flurry.Git.Transport)
      snapshot = adapter.fetch(source, credentials, directory)

      case source.operation do
        "import" -> initial(repository, user, source, snapshot, directory)
        "pull" -> pull(repository, user, source, snapshot)
        "push" -> push(repository, user, source, snapshot, adapter, credentials, directory)
      end

      Flurry.Audit.record(user, "source." <> source.operation <> ".complete", repository)
    rescue
      error in Error -> fail(source, error.message)
      _ -> fail(source, "The transfer failed. Check the source and retry.")
    after
      File.rm_rf(directory)
    end
  end

  def fail(source, message), do: persist(source, status: "failed", error: message, message: nil)

  defp initial(repository, user, source, snapshot, directory) do
    {:ok, _} =
      Repo.transaction(fn ->
        ref = ref(repository)
        Repositories.writable!(repository)

        if ref.head,
          do:
            Error.fail(
              "This repository now contains changes; import into a new repository instead",
              409
            )

        result =
          if snapshot[:full_history] do
            Flurry.Git.Import.initial(
              repository,
              user,
              directory,
              snapshot.commit,
              "main"
            )
          else
            change =
              Changesets.insert(
                repository,
                user.id,
                nil,
                nil,
                "Import #{snapshot.branch} from source",
                snapshot.files,
                snapshot.root
              )

            Repo.update_all(from(r in "refs", where: r.id == ^ref.id), set: [head: change.id])
            %{"head" => change.id}
          end

        persist(
          source,
          shared(snapshot) ++
            [message: "Imported full history ending at #{result["head"]}"]
        )
      end)
  end

  defp pull(repository, user, source, snapshot) do
    base = Tree.files(source.root)
    incoming = snapshot.files
    upstream = delta(base, incoming)

    {:ok, _} =
      Repo.transaction(fn ->
        ref = ref(repository)
        current = Changesets.root(repository, ref.head) |> Tree.files()
        Repositories.writable!(repository)

        conflicts =
          Map.keys(upstream)
          |> Enum.filter(fn path ->
            Map.get(current, path) != Map.get(base, path) and
              Map.get(current, path) != Map.get(incoming, path)
          end)

        if conflicts != [],
          do:
            Error.fail(
              "Both Flurry and upstream changed: #{Enum.join(conflicts, ", ")}. Resolve those files before pulling again.",
              409
            )

        changes = Map.reject(upstream, fn {path, hash} -> Map.get(current, path) == hash end)

        if map_size(changes) == 0 do
          persist(source, shared(snapshot) ++ [message: "Already up to date"])
        else
          merged =
            Enum.reduce(changes, current, fn {path, hash}, files ->
              if hash, do: Map.put(files, path, hash), else: Map.delete(files, path)
            end)

          # Tree.apply validates structural collisions before publishing a review
          root = Changesets.root(repository, ref.head) |> Tree.apply(changes)
          if Tree.files(root) != merged, do: Error.fail("Source tree validation failed", 500)

          change =
            Changesets.insert(
              repository,
              user.id,
              ref.head,
              nil,
              "Pull updates from #{snapshot.branch}",
              changes,
              root
            )

          review =
            Repo.insert!(%Review{
              id: Ecto.UUID.generate(),
              repository_id: repository.id,
              changeset_id: change.id
            })

          ReviewFindings.automatic(repository, review, user, :review_opened)

          persist(source,
            status: "ready",
            review_id: review.id,
            incoming_commit: snapshot.commit,
            incoming_root: snapshot.root,
            incoming_modes: snapshot.modes,
            branch: snapshot.branch,
            message: "Upstream updates are ready for review"
          )
        end
      end)
  end

  defp push(repository, user, source, snapshot, adapter, credentials, directory) do
    cond do
      source.push_commit && snapshot.commit == source.push_commit ->
        fields =
          shared(%{
            commit: source.push_commit,
            root: source.push_root,
            modes: source.push_modes,
            branch: source.branch
          }) ++ clear_push()

        persist(source, fields)
        confirmed = source |> Ecto.Changeset.change(fields) |> Ecto.Changeset.apply_changes()
        push(repository, user, confirmed, snapshot, adapter, credentials, directory)

      snapshot.commit != source.commit ->
        Error.fail(
          "Upstream has new commits. Pull updates and land the review before pushing.",
          409
        )

      true ->
        head = source.requested_head
        unless head, do: Error.fail("Select a landed revision to push")
        root = Changesets.root(repository, head)

        if root == source.root do
          persist(source, status: "ready", message: "Nothing to push")
        else
          commit = Export.commit(directory, root, source.modes, source.commit, user, head)
          persist(source, push_commit: commit, push_root: root, push_modes: source.modes)
          adapter.push(source, credentials, directory, commit)

          persist(
            source,
            shared(%{commit: commit, root: root, modes: source.modes, branch: source.branch}) ++
              clear_push() ++ [message: "Pushed landed changes to #{source.branch}"]
          )
        end
    end
  end

  defp shared(snapshot),
    do: [
      commit: snapshot.commit,
      root: snapshot.root,
      modes: snapshot.modes,
      branch: snapshot.branch,
      synced_at: DateTime.utc_now(),
      status: "ready",
      error: nil
    ]

  defp clear_push, do: [push_commit: nil, push_root: nil, push_modes: nil]

  defp persist(source, fields) do
    Repo.update_all(
      from(s in Source, where: s.repository_id == ^source.repository_id and s.job == ^source.job),
      set: fields ++ [updated_at: DateTime.utc_now()]
    )
  end

  defp delta(before, next) do
    (Map.keys(before) ++ Map.keys(next))
    |> Enum.uniq()
    |> Enum.reject(&(Map.get(before, &1) == Map.get(next, &1)))
    |> Map.new(&{&1, Map.get(next, &1)})
  end

  defp ref(repository),
    do:
      Repo.one!(
        from(r in "refs",
          where: r.repository_id == ^Ecto.UUID.dump!(repository.id) and r.name == "main",
          lock: "FOR UPDATE",
          select: %{id: r.id, head: r.head}
        )
      )
end
