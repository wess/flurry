defmodule Flurry.Engine.Archives do
  alias Flurry.Engine.Changesets
  alias Flurry.Store.{Objects, Tree}

  def create(repository, revision) do
    prefix = repository.name <> "-" <> String.slice(revision, 0, 12)

    entries =
      repository
      |> Changesets.root(revision)
      |> Tree.files()
      |> Enum.sort()
      |> Enum.map(fn {path, hash} ->
        {String.to_charlist(prefix <> "/" <> path), Objects.get(:blob, hash)}
      end)

    name = "flurry-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> ".tar.gz"
    target = Path.join(System.tmp_dir!(), name)

    try do
      :ok = :erl_tar.create(String.to_charlist(target), entries, [:compressed])
      File.read!(target)
    after
      File.rm(target)
    end
  end
end
