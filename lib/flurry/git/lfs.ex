defmodule Flurry.Git.Lfs do
  import Ecto.Query

  alias Flurry.{Error, Repo}
  alias Flurry.Engine.Repositories
  alias Flurry.Schema.{LfsLock, LfsObject, User}
  alias Flurry.Store.Tree

  @max_objects 100
  @max_bytes 2_147_483_648

  def batch(repository, user, attrs, base_url) do
    operation = attrs["operation"]
    objects = attrs["objects"]

    unless operation in ["upload", "download"] and is_list(objects) and
             length(objects) <= @max_objects,
           do: Error.fail("Invalid large-file batch request")

    if operation == "upload" and is_nil(user), do: Error.fail("Authentication required", 401)

    if operation == "upload" do
      {:ok, result} =
        Repo.transaction(fn ->
          %{
            transfer: "basic",
            objects: Enum.map(objects, &batch_object(repository, operation, &1, base_url))
          }
        end)

      result
    else
      %{
        transfer: "basic",
        objects: Enum.map(objects, &batch_object(repository, operation, &1, base_url))
      }
    end
  end

  def receive(repository, oid, conn) do
    oid!(oid)

    object =
      Repo.get_by(LfsObject, repository_id: repository.id, oid: oid) ||
        Error.fail("Large-file object was not announced", 404)

    if object.uploaded_at, do: Error.fail("Large-file object already exists", 409)
    directory = Path.dirname(path(oid))
    File.mkdir_p!(directory)
    temporary = Path.join(directory, ".#{oid}.#{Ecto.UUID.generate()}")

    try do
      {:ok, file} = :file.open(String.to_charlist(temporary), [:write, :binary, :exclusive, :raw])

      try do
        {conn, bytes, digest} = stream(conn, file, object.size)

        unless bytes == object.size and digest == oid,
          do: Error.fail("Large-file object size or digest does not match", 422)

        :ok = :file.sync(file)
        :ok = :file.close(file)

        if File.exists?(path(oid)),
          do: File.rm!(temporary),
          else: File.rename!(temporary, path(oid))

        object
        |> Ecto.Changeset.change(uploaded_at: DateTime.utc_now())
        |> Repo.update!()

        conn
      after
        :file.close(file)
      end
    after
      File.rm(temporary)
    end
  end

  def object(repository, oid) do
    oid!(oid)

    object =
      Repo.get_by(LfsObject, repository_id: repository.id, oid: oid) ||
        Error.fail("Large-file object not found", 404)

    unless not is_nil(object.uploaded_at) and File.regular?(path(oid)),
      do: Error.fail("Large-file object not found", 404)

    {object, path(oid)}
  end

  def create_lock(repository, user, attrs) do
    value = get_in(attrs, ["path"])
    unless is_binary(value), do: Error.fail("Lock path is required")
    path = Tree.path!(value)

    lock =
      %LfsLock{}
      |> Ecto.Changeset.change(
        id: Ecto.UUID.generate(),
        repository_id: repository.id,
        owner_id: user.id,
        path: path
      )
      |> Ecto.Changeset.unique_constraint(:path)

    case Repo.insert(lock) do
      {:ok, lock} -> %{lock: lock_public(lock)}
      {:error, _} -> Error.fail("Path is already locked", 409)
    end
  end

  def locks(repository, params \\ %{}) do
    path = params["path"]

    query =
      from(l in LfsLock,
        where: l.repository_id == ^repository.id,
        order_by: [asc: l.inserted_at, asc: l.id],
        limit: 100
      )

    query = if is_binary(path), do: from(l in query, where: l.path == ^path), else: query
    %{locks: Repo.all(query) |> Enum.map(&lock_public/1), next_cursor: ""}
  end

  def verify_locks(repository, user) do
    values =
      Repo.all(
        from(l in LfsLock,
          where: l.repository_id == ^repository.id,
          order_by: [asc: l.inserted_at, asc: l.id],
          limit: 100
        )
      )

    {ours, theirs} = Enum.split_with(values, &(&1.owner_id == user.id))

    %{
      ours: Enum.map(ours, &lock_public/1),
      theirs: Enum.map(theirs, &lock_public/1),
      next_cursor: ""
    }
  end

  def unlock(repository, user, id, attrs) do
    lock =
      Repo.get_by(LfsLock, id: id, repository_id: repository.id) ||
        Error.fail("Lock not found", 404)

    force = attrs["force"] == true

    unless lock.owner_id == user.id or
             (force and Repositories.permitted?(repository, user, :review)),
           do: Error.fail("Only the lock owner or a maintainer can unlock this path", 403)

    Repo.delete!(lock)
    %{lock: lock_public(lock)}
  end

  def path(oid) do
    Path.join([
      Application.fetch_env!(:flurry, :store),
      "lfs",
      String.slice(oid, 0, 2),
      oid
    ])
  end

  defp batch_object(repository, operation, attrs, base_url) do
    oid = oid!(attrs["oid"])
    size = size!(attrs["size"])
    existing = Repo.get_by(LfsObject, repository_id: repository.id, oid: oid)

    if operation == "upload", do: Flurry.Quota.reserve_lfs!(repository, oid, size)

    if existing && existing.size != size,
      do: Error.fail("Large-file object size conflicts with its existing declaration", 409)

    object =
      if operation == "upload" do
        existing || Repo.insert!(%LfsObject{repository_id: repository.id, oid: oid, size: size})
      else
        existing
      end

    href = "#{base_url}/objects/#{oid}"

    cond do
      operation == "upload" and is_nil(object.uploaded_at) ->
        %{oid: oid, size: size, actions: %{upload: %{href: href, header: %{}}}}

      operation == "upload" ->
        %{oid: oid, size: size}

      object && object.uploaded_at && File.regular?(path(oid)) ->
        %{oid: oid, size: size, actions: %{download: %{href: href, header: %{}}}}

      true ->
        %{oid: oid, size: size, error: %{code: 404, message: "Object not found"}}
    end
  end

  defp stream(conn, file, expected) do
    stream(conn, file, expected, 0, :crypto.hash_init(:sha256))
  end

  defp stream(conn, file, expected, total, hash) do
    case Plug.Conn.read_body(conn,
           length: expected + 1,
           read_length: 1_048_576,
           read_timeout: 30_000
         ) do
      {status, bytes, conn} when status in [:ok, :more] ->
        total = total + byte_size(bytes)
        if total > expected, do: Error.fail("Large-file upload exceeds its declared size", 413)
        :ok = :file.write(file, bytes)
        hash = :crypto.hash_update(hash, bytes)

        if status == :ok do
          digest = :crypto.hash_final(hash) |> Base.encode16(case: :lower)
          {conn, total, digest}
        else
          stream(conn, file, expected, total, hash)
        end

      {:error, _} ->
        Error.fail("Could not read large-file upload")
    end
  end

  defp lock_public(lock) do
    owner = Repo.get!(User, lock.owner_id)

    %{
      id: lock.id,
      path: lock.path,
      locked_at: lock.inserted_at,
      owner: %{name: owner.name, username: owner.username}
    }
  end

  defp oid!(oid) do
    unless is_binary(oid) and Regex.match?(~r/\A[0-9a-f]{64}\z/, oid),
      do: Error.fail("Invalid large-file object identifier")

    oid
  end

  defp size!(size) when is_integer(size) and size in 0..@max_bytes, do: size
  defp size!(_), do: Error.fail("Invalid large-file object size")
end
