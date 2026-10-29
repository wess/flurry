defmodule Flurry.Quota do
  import Ecto.Query
  alias Flurry.{Repo, Instance, Error, Schema.User, Schema.Repository, Store.Objects}

  def file_limit(_user), do: Instance.limits().file_bytes

  def repository!(_user), do: :ok

  def record(repository, changes) do
    owner = lock(repository.owner_id)
    hydrate(owner)
    hashes = changes |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.uniq()

    known =
      Repo.all(
        from(o in "repositoryobjects",
          where: o.repository_id == ^Ecto.UUID.dump!(repository.id) and o.hash in ^hashes,
          select: o.hash
        )
      )
      |> MapSet.new()

    records =
      hashes
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.map(fn hash ->
        %{
          repository_id: Ecto.UUID.dump!(repository.id),
          hash: hash,
          bytes: byte_size(Objects.get(:blob, hash))
        }
      end)

    limits = Instance.limits()

    if Enum.any?(records, &(&1.bytes > file_limit(owner))),
      do: Error.fail("This file exceeds the instance file-size limit", 413)

    used = used(owner)
    added = Enum.sum(Enum.map(records, & &1.bytes))

    if limits.project_storage_bytes > 0 and
         project_used(repository) + added > limits.project_storage_bytes,
       do:
         Error.fail(
           "Project storage limit reached. Existing files remain available.",
           409
         )

    if limits.account_storage_bytes > 0 and used + added > limits.account_storage_bytes,
      do:
        Error.fail(
          "Account storage limit reached. Existing files remain available.",
          409
        )

    Enum.chunk_every(records, 1000)
    |> Enum.each(&Repo.insert_all("repositoryobjects", &1, on_conflict: :nothing))
  end

  def usage(user) do
    {:ok, result} =
      Repo.transaction(fn ->
        user = lock(user.id)
        hydrate(user)

        %{
          bytes: used(user),
          repositories:
            Repo.aggregate(
              from(r in Repository, where: r.owner_id == ^user.id and is_nil(r.deleted_at)),
              :count
            )
        }
      end)

    result
  end

  def reserve_lfs!(repository, oid, bytes) do
    owner = lock(repository.owner_id)
    limits = Instance.limits()

    existing =
      Repo.one(
        from(o in "lfs_objects",
          where: o.repository_id == ^Ecto.UUID.dump!(repository.id) and o.oid == ^oid,
          select: o.size
        )
      )

    if existing && existing != bytes,
      do: Error.fail("Large-file object size conflicts with its existing declaration", 409)

    reserved = if existing, do: 0, else: bytes

    if limits.project_storage_bytes > 0 and
         project_used(repository) + project_pending_lfs(repository) + reserved >
           limits.project_storage_bytes,
       do:
         Error.fail(
           "Project storage limit reached. Existing large-file objects remain available.",
           409
         )

    if limits.account_storage_bytes > 0 and
         used(owner) + pending_lfs(owner) + reserved > limits.account_storage_bytes,
       do:
         Error.fail(
           "Account storage limit reached. Existing large-file objects remain available.",
           409
         )
  end

  defp lock(id), do: Repo.one!(from(u in User, where: u.id == ^id, lock: "FOR UPDATE"))

  defp used(user) do
    source =
      Repo.one(
        from(o in "repositoryobjects",
          join: r in Repository,
          on: r.id == o.repository_id,
          where: r.owner_id == ^user.id,
          select: coalesce(sum(o.bytes), 0)
        )
      )
      |> Decimal.to_integer()

    source + uploaded_lfs(user)
  end

  defp uploaded_lfs(user),
    do:
      Repo.one(
        from(o in "lfs_objects",
          join: r in Repository,
          on: r.id == o.repository_id,
          where: r.owner_id == ^user.id and not is_nil(o.uploaded_at),
          select: coalesce(sum(o.size), 0)
        )
      )
      |> Decimal.to_integer()

  defp pending_lfs(user),
    do:
      Repo.one(
        from(o in "lfs_objects",
          join: r in Repository,
          on: r.id == o.repository_id,
          where: r.owner_id == ^user.id and is_nil(o.uploaded_at),
          select: coalesce(sum(o.size), 0)
        )
      )
      |> Decimal.to_integer()

  defp project_used(repository) do
    source =
      Repo.one(
        from(o in "repositoryobjects",
          where: o.repository_id == ^Ecto.UUID.dump!(repository.id),
          select: coalesce(sum(o.bytes), 0)
        )
      )
      |> Decimal.to_integer()

    lfs =
      Repo.one(
        from(o in "lfs_objects",
          where: o.repository_id == ^Ecto.UUID.dump!(repository.id) and not is_nil(o.uploaded_at),
          select: coalesce(sum(o.size), 0)
        )
      )
      |> Decimal.to_integer()

    source + lfs
  end

  defp project_pending_lfs(repository),
    do:
      Repo.one(
        from(o in "lfs_objects",
          where: o.repository_id == ^Ecto.UUID.dump!(repository.id) and is_nil(o.uploaded_at),
          select: coalesce(sum(o.size), 0)
        )
      )
      |> Decimal.to_integer()

  defp hydrate(%{storage_migrated: true}), do: :ok

  defp hydrate(user) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT c.repository_id, f.value #>> '{}' FROM changesets c
        JOIN repositories r ON r.id = c.repository_id
        CROSS JOIN LATERAL jsonb_each(c.changes) f WHERE r.owner_id = $1 AND f.value <> 'null'::jsonb
        """,
        [Ecto.UUID.dump!(user.id)]
      )

    records =
      Enum.map(rows, fn [id, hash] ->
        %{repository_id: id, hash: hash, bytes: byte_size(Objects.get(:blob, hash))}
      end)

    Enum.chunk_every(records, 1000)
    |> Enum.each(&Repo.insert_all("repositoryobjects", &1, on_conflict: :nothing))

    user |> Ecto.Changeset.change(storage_migrated: true) |> Repo.update!()
  end
end
