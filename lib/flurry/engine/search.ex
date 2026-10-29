defmodule Flurry.Engine.Search do
  alias Flurry.Auth
  alias Flurry.Engine.Changesets
  alias Flurry.Store.{Objects, Tree}

  @scan_bytes 16 * 1024 * 1024
  @result_limit 100

  def code(repository, revision, attrs) do
    query = Auth.text!(attrs["query"], "Search query", 200)
    folded = String.downcase(query)

    {matches, _, truncated} =
      repository
      |> Changesets.root(revision)
      |> Tree.files()
      |> Enum.sort()
      |> Enum.reduce_while({[], 0, false}, fn {path, hash}, {matches, bytes, _} ->
        if length(matches) >= @result_limit or bytes >= @scan_bytes do
          {:halt, {matches, bytes, true}}
        else
          data = Objects.get(:blob, hash)
          next = if text?(data), do: find(data, path, hash, folded, matches), else: matches
          {:cont, {next, bytes + byte_size(data), false}}
        end
      end)

    %{
      revision: revision,
      query: query,
      matches: Enum.reverse(matches),
      truncated: truncated or length(matches) >= @result_limit
    }
  end

  def paths(repository, revision, attrs) do
    query = Auth.text!(attrs["query"], "Search query", 200)
    folded = String.downcase(query)

    matches =
      repository
      |> Changesets.root(revision)
      |> Tree.files()
      |> Map.keys()
      |> Enum.filter(&String.contains?(String.downcase(&1), folded))
      |> Enum.sort()

    %{
      revision: revision,
      query: query,
      paths: Enum.take(matches, @result_limit),
      truncated: length(matches) > @result_limit
    }
  end

  defp find(data, path, hash, query, matches) do
    data
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce(matches, fn {line, number}, found ->
      if length(found) < @result_limit and String.contains?(String.downcase(line), query) do
        [%{path: path, line: number, text: String.slice(line, 0, 500), hash: hash} | found]
      else
        found
      end
    end)
  end

  defp text?(data), do: String.valid?(data) and not String.contains?(data, <<0>>)
end
