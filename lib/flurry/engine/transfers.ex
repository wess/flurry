defmodule Flurry.Engine.Transfers do
  import Ecto.Query
  alias Flurry.{Repo, Error, Auth, Schema.Review, Schema.User, Store.Tree, Store.Objects}
  alias Flurry.Engine.{Repositories, Changesets, Refs, Graph, Keys, Policies, ReviewFindings}

  def receipt(repository, user, request) do
    unless match?({:ok, _}, Ecto.UUID.cast(request)), do: Error.fail("Invalid push request")

    {:ok, result} =
      Repo.transaction(fn ->
        Repositories.lock(repository)

        row =
          Repo.one(
            from(p in "pushes",
              where:
                p.repository_id == ^Ecto.UUID.dump!(repository.id) and
                  p.request_id == ^Ecto.UUID.dump!(request),
              select: %{author: p.author_id, result: p.result}
            )
          )

        if row do
          unless row.author == Ecto.UUID.dump!(user.id),
            do: Error.fail("This push belongs to another user", 403)

          %{accepted: true, result: row.result}
        else
          %{accepted: false}
        end
      end)

    result
  end

  def push(repository, user, attrs, options \\ []) do
    request = attrs["request_id"]

    unless match?({:ok, _}, Ecto.UUID.cast(request)),
      do: Error.fail("Push requires a UUID request_id")

    branch = Refs.name!(attrs["branch"])
    expected = attrs["expected"]
    if expected, do: Changesets.get(repository, expected)
    commits = attrs["commits"]
    max_commits = options[:max_commits] || 100
    max_files = options[:max_files] || 100

    unless is_list(commits) and length(commits) <= max_commits,
      do: Error.fail("Push at most #{max_commits} commits")

    digest = Jason.encode!(canonical(attrs)) |> Objects.digest()

    {:ok, result} =
      Repo.transaction(fn ->
        Repositories.lock(repository)
        Repositories.writable!(repository)
        Policies.enforce_push!(repository, user)

        if options[:initial_import] != true and
             Repo.exists?(
               from(s in Flurry.Schema.Source,
                 where: s.repository_id == ^repository.id and is_nil(s.commit)
               )
             ),
           do: Error.fail("Complete the initial source import before pushing commits", 409)

        previous =
          Repo.one(
            from(p in "pushes",
              where:
                p.repository_id == ^Ecto.UUID.dump!(repository.id) and
                  p.request_id == ^Ecto.UUID.dump!(request),
              select: %{author: p.author_id, digest: p.digest, result: p.result}
            )
          )

        if previous do
          unless previous.author == Ecto.UUID.dump!(user.id) and previous.digest == digest,
            do: Error.fail("Push request_id was already used with different content", 409)

          previous.result
        else
          Refs.available!(repository, :branch, branch)
          current = Refs.head(repository, branch)

          unless current == expected,
            do: Error.fail("Remote branch advanced; fetch before pushing", 409)

          mapping =
            Enum.reduce(commits, %{}, fn entry, mapping ->
              unless is_map(entry), do: Error.fail("Invalid commit entry")
              key = entry["id"]

              unless match?({:ok, _}, Ecto.UUID.cast(key)) and not Map.has_key?(mapping, key),
                do: Error.fail("Each commit requires a unique UUID")

              parent = resolve(repository, entry["parent"], mapping)
              merge = resolve(repository, entry["merge_parent"], mapping)
              if merge && merge == parent, do: Error.fail("Merge parents must differ")
              root = Changesets.root(repository, parent)

              changes =
                Changesets.prepare(
                  entry["files"],
                  root,
                  Flurry.Quota.file_limit(Repo.get!(User, repository.owner_id)),
                  true,
                  max_files
                )

              message = Auth.text!(entry["message"], "Commit message", 2000)

              next_root = Tree.apply(root, changes) |> Tree.portable!()

              signature_digest =
                Changesets.signature_digest(repository.id, parent, merge, message, changes)

              verified =
                Keys.verify_signature(
                  user,
                  signature_digest,
                  entry["signature"],
                  repository.require_signed_commits
                )

              existing =
                if is_map(entry["git"]) do
                  Repo.one(
                    from(g in "gitcommits",
                      where:
                        g.repository_id == ^Ecto.UUID.dump!(repository.id) and
                          g.git == ^entry["git"]["id"],
                      limit: 1,
                      select: g.native
                    )
                  )
                end

              inserted =
                if existing do
                  change = Changesets.get(repository, existing)

                  unless change.parent_id == parent and change.merge_parent_id == merge and
                           Changesets.root(repository, existing) == next_root,
                         do:
                           Error.fail(
                             "Git identity already maps to different Flurry content",
                             409
                           )

                  change
                else
                  Changesets.insert(
                    repository,
                    user.id,
                    parent,
                    nil,
                    message,
                    changes,
                    next_root,
                    merge
                  )
                end

              Flurry.Git.View.attach(repository, inserted, entry["git"])
              Keys.record_signature(inserted.id, verified)
              Map.put(mapping, key, inserted.id)
            end)

          tip = resolve(repository, attrs["head"], mapping)

          unless tip && Graph.ancestor?(repository, current, tip),
            do: Error.fail("Non-fast-forward push rejected", 409)

          {review, review_opened} =
            if branch == "main" and current != tip and options[:direct_main] != true do
              existing =
                Repo.one(
                  from(r in Review,
                    where:
                      r.repository_id == ^repository.id and r.changeset_id == ^tip and
                        fragment("? IS NOT DISTINCT FROM ?", r.base_id, ^current) and
                        r.status in ["open", "approved"],
                    limit: 1
                  )
                )

              if existing do
                {existing, false}
              else
                {Repo.insert!(%Review{
                   id: Ecto.UUID.generate(),
                   repository_id: repository.id,
                   changeset_id: tip,
                   series: true,
                   base_id: current
                 }), true}
              end
            else
              {nil, false}
            end

          if review_opened, do: ReviewFindings.automatic(repository, review, user, :review_opened)

          if branch != "main" or options[:direct_main] do
            Repo.insert_all(
              "refs",
              [%{repository_id: Ecto.UUID.dump!(repository.id), name: branch, head: tip}],
              on_conflict: [set: [head: tip]],
              conflict_target: [:repository_id, :name]
            )
          end

          result =
            %{
              head: tip,
              branch: branch,
              commits: mapping,
              review_id: if(review, do: review.id),
              protected: branch == "main" and options[:direct_main] != true
            }
            |> Jason.encode!()
            |> Jason.decode!()

          Repo.insert_all("pushes", [
            %{
              repository_id: Ecto.UUID.dump!(repository.id),
              request_id: Ecto.UUID.dump!(request),
              author_id: Ecto.UUID.dump!(user.id),
              digest: digest,
              result: result,
              inserted_at: DateTime.utc_now()
            }
          ])

          Flurry.Audit.record(user, "branch.push", repository, %{branch: branch, head: tip})
          result
        end
      end)

    result
  end

  defp resolve(_, nil, _), do: nil

  defp resolve(repository, id, mapping) do
    Map.get(mapping, id) || Changesets.get(repository, id).id
  end

  defp canonical(map) when is_map(map),
    do: map |> Enum.sort() |> Enum.map(fn {k, v} -> [k, canonical(v)] end)

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
end
