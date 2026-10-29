defmodule Flurry.Store.Objects do
  alias Flurry.Error

  def put(type, data) when type in [:blob, :tree] and is_binary(data) do
    payload = Atom.to_string(type) <> <<0>> <> data
    hash = digest(payload)
    driver().put(hash, :zlib.compress(payload))

    hash
  end

  def get(type, hash) do
    validate!(hash)
    payload = hash |> driver().get() |> uncompress!()
    if digest(payload) != hash, do: Error.fail("Object integrity check failed", 500)
    prefix = Atom.to_string(type) <> <<0>>
    size = byte_size(prefix)

    case payload do
      <<^prefix::binary-size(size), data::binary>> -> data
      _ -> Error.fail("Object type mismatch", 500)
    end
  end

  def digest(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  def validate!(hash) do
    unless is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash),
      do: Error.fail("Invalid object identifier")

    hash
  end

  def driver, do: Application.get_env(:flurry, :object_driver, Flurry.Store.Local)

  def description do
    case driver() do
      Flurry.Store.S3 -> "Private S3-compatible content-addressed storage"
      _ -> "Local content-addressed storage"
    end
  end

  defp uncompress!(data) do
    :zlib.uncompress(data)
  rescue
    ErlangError -> Error.fail("Object compression is invalid", 500)
  end
end
