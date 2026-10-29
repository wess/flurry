defmodule Flurry.Store.Migration do
  alias Flurry.Store.{Local, Objects, S3}

  def migrate_local_to_s3 do
    config = S3.config()

    results =
      local_objects()
      |> Enum.map(fn hash ->
        compressed = hash |> Local.path() |> File.read!()
        :ok = S3.put(hash, compressed, config)
        ^compressed = S3.get(hash, config)
        hash
      end)

    %{migrated: length(results), verified: length(results)}
  end

  def verify_local_against_s3 do
    config = S3.config()
    hashes = local_objects()

    verified =
      Enum.count(hashes, fn hash ->
        hash |> Local.path() |> File.read!() == S3.get(hash, config)
      end)

    %{local: length(hashes), verified: verified}
  end

  def probe_s3 do
    payload = "blob" <> <<0>> <> "Flurry object-storage probe\n"
    hash = Objects.digest(payload)
    compressed = :zlib.compress(payload)
    config = S3.config()
    :ok = S3.put(hash, compressed, config)
    ^compressed = S3.get(hash, config)
    %{ok: true, key: S3.key(hash, config)}
  end

  defp local_objects do
    root = Application.fetch_env!(:flurry, :store)

    Path.wildcard(Path.join([root, "[0-9a-f][0-9a-f]", "*"]))
    |> Enum.map(&Path.basename/1)
    |> Enum.filter(&Regex.match?(~r/\A[0-9a-f]{64}\z/, &1))
    |> Enum.sort()
  end
end
