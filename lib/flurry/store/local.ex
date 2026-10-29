defmodule Flurry.Store.Local do
  def put(hash, compressed) do
    target = path(hash)
    File.mkdir_p!(Path.dirname(target))

    if File.exists?(target) do
      :ok
    else
      temporary = target <> "." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

      try do
        {:ok, file} =
          :file.open(String.to_charlist(temporary), [:write, :binary, :exclusive, :raw])

        try do
          :ok = :file.write(file, compressed)
          :ok = :file.sync(file)
        after
          :file.close(file)
        end

        File.rename!(temporary, target)
        sync_directory!(Path.dirname(target))
      after
        File.rm(temporary)
      end
    end

    :ok
  end

  def get(hash), do: hash |> path() |> File.read!()

  def path(hash),
    do: Path.join([Application.fetch_env!(:flurry, :store), String.slice(hash, 0, 2), hash])

  defp sync_directory!(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, directory} ->
        try do
          :ok = :file.sync(directory)
        after
          :file.close(directory)
        end

      {:error, reason} ->
        if reason in [:eisdir, :enotsup, :einval, :eacces],
          do: :ok,
          else: raise(File.Error, reason: reason, action: "sync directory", path: path)
    end
  end
end
