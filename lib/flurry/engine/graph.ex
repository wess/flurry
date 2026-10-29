defmodule Flurry.Engine.Graph do
  import Ecto.Query
  alias Flurry.{Repo, Error, Schema.Changeset}

  def ancestors(_repository, nil), do: %{nil => 0}

  def ancestors(repository, id) do
    Flurry.Engine.Changesets.get(repository, id)
    walk(repository, [{id, 0}], %{})
  end

  defp walk(_, [], seen), do: seen

  defp walk(repository, pending, seen) do
    if map_size(seen) > 10_000,
      do: Error.fail("Ancestry exceeds the current 10,000 revision traversal limit", 413)

    {batch, rest} = Enum.split(pending, 100)
    batch = Enum.reject(batch, fn {id, _} -> Map.has_key?(seen, id) end)
    depths = Map.new(batch)
    ids = Map.keys(depths) |> Enum.reject(&is_nil/1)

    nodes =
      Repo.all(from(c in Changeset, where: c.repository_id == ^repository.id and c.id in ^ids))

    seen = Enum.reduce(batch, seen, fn {id, depth}, acc -> Map.put_new(acc, id, depth) end)

    next =
      Enum.flat_map(nodes, fn node ->
        depth = depths[node.id] + 1

        parents =
          [node.parent_id] ++ if(node.merge_parent_id, do: [node.merge_parent_id], else: [])

        Enum.map(parents, &{&1, depth})
      end)

    walk(repository, rest ++ next, seen)
  end

  def ancestor?(repository, ancestor, descendant),
    do: Map.has_key?(ancestors(repository, descendant), ancestor)

  def merge_base(repository, left, right) do
    a = ancestors(repository, left)
    b = ancestors(repository, right)
    common = Map.keys(a) |> Enum.filter(&Map.has_key?(b, &1))

    ids = Enum.reject(common, &is_nil/1)

    parents =
      Repo.all(
        from(c in Changeset,
          where: c.repository_id == ^repository.id and c.id in ^ids,
          select: {c.parent_id, c.merge_parent_id}
        )
      )
      |> Enum.flat_map(fn {first, second} -> [first] ++ if(second, do: [second], else: []) end)
      |> MapSet.new()

    candidates = Enum.reject(common, &MapSet.member?(parents, &1))

    case candidates do
      [base] -> base
      [] -> nil
      _ -> Error.fail("Multiple merge bases require manual resolution", 409)
    end
  end
end
