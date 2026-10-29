defmodule Flurry.Git.Export do
  alias Flurry.{Error, Store.Tree, Store.Objects}
  alias Flurry.Git.Command

  def commit(directory, root, modes, parent, user, head) do
    message = "Update from Flurry\n\nFlurry-Changeset: #{head}\n"
    file = Path.join(directory, "message")
    File.write!(file, message)
    tree = tree(directory, root, modes, "")
    name = String.replace(user.name, ["\r", "\n", "<", ">"], "")
    email = user.username <> "@users.flurry.invalid"

    Command.run(directory, ["commit-tree", tree, "-p", parent, "-F", file],
      env: [
        {"GIT_AUTHOR_NAME", name},
        {"GIT_AUTHOR_EMAIL", email},
        {"GIT_COMMITTER_NAME", name},
        {"GIT_COMMITTER_EMAIL", email}
      ]
    )
    |> String.trim()
  end

  defp tree(directory, root, modes, prefix) do
    payload =
      Tree.read(root)
      |> Enum.sort_by(fn {name, entry} ->
        name <> if(entry["type"] == "tree", do: "/", else: "")
      end)
      |> Enum.map(fn {name, entry} ->
        path = if prefix == "", do: name, else: prefix <> "/" <> name

        {mode, hash} =
          if entry["type"] == "tree" do
            {"40000", tree(directory, entry["hash"], modes, path)}
          else
            mode = Map.get(modes, path, "100644")
            unless mode in ["100644", "100755"], do: Error.fail("Unsupported export file mode")
            data = Objects.get(:blob, entry["hash"])
            {mode, object(directory, "blob", data)}
          end

        [mode, " ", name, <<0>>, Base.decode16!(hash, case: :lower)]
      end)
      |> IO.iodata_to_binary()

    object(directory, "tree", payload)
  end

  defp object(directory, type, payload) do
    temporary = Path.join(directory, "payload")
    File.write!(temporary, payload)

    Command.run(directory, ["hash-object", "-w", "--no-filters", "-t", type, "--", temporary])
    |> String.trim()
  end
end
