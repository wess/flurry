defmodule Flurry.Engine.Refs do
  import Ecto.Query
  alias Flurry.{Repo, Error}
  alias Flurry.Engine.{Repositories, Changesets}

  def name!(name) do
    unless is_binary(name) and byte_size(name) in 1..200 and
             Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._\/-]*\z/, name) and
             not String.contains?(name, ["..", "//", "@{", "\\"]) and
             Enum.all?(
               String.split(name, "/"),
               &(not String.starts_with?(&1, ".") and not String.ends_with?(&1, [".", ".lock"]) and
                   &1 != "")
             ),
           do: Error.fail("Invalid branch or tag name")

    name
  end

  def list(repository) do
    id = Ecto.UUID.dump!(repository.id)

    %{
      branches:
        Repo.all(
          from(r in "refs",
            where: r.repository_id == ^id,
            order_by: r.name,
            select: %{name: r.name, head: r.head}
          )
        ),
      tags:
        Repo.all(
          from(t in "tags",
            where: t.repository_id == ^id,
            order_by: t.name,
            select: %{
              name: t.name,
              target: t.target,
              message: t.message,
              git: t.git,
              raw: fragment("replace(encode(?, 'base64'), chr(10), '')", t.raw)
            }
          )
        )
    }
  end

  def head(repository, branch) do
    name!(branch)

    Repo.one(
      from(r in "refs",
        where: r.repository_id == ^Ecto.UUID.dump!(repository.id) and r.name == ^branch,
        select: r.head
      )
    )
  end

  def delete_branch(repository, actor, name, expected) do
    name!(name)
    if name == "main", do: Error.fail("Main cannot be deleted", 409)

    {:ok, result} =
      Repo.transaction(fn ->
        Repositories.lock(repository)
        Repositories.writable!(repository)
        Flurry.Engine.Policies.enforce_push!(repository, actor)

        current = head(repository, name)
        if is_nil(current), do: Error.fail("Branch not found", 404)

        unless current == expected,
          do: Error.fail("Remote branch advanced; fetch before deleting", 409)

        Repo.delete_all(
          from(r in "refs",
            where:
              r.repository_id == ^Ecto.UUID.dump!(repository.id) and r.name == ^name and
                r.head == ^expected
          )
        )

        Flurry.Audit.record(actor, "branch.delete", repository, %{name: name, head: expected})
        %{name: name, deleted: true}
      end)

    result
  end

  def available!(repository, kind, name) when kind in [:branch, :tag] do
    table = if kind == :branch, do: "refs", else: "tags"

    existing =
      Repo.all(
        from(r in table,
          where: r.repository_id == ^Ecto.UUID.dump!(repository.id),
          select: r.name
        )
      )

    folded = String.downcase(name)

    if Enum.any?(existing, fn current ->
         other = String.downcase(current)

         current != name and
           (case_alias?(current, name) or other == folded or
              String.starts_with?(other, folded <> "/") or
              String.starts_with?(folded, other <> "/"))
       end),
       do: Error.fail("Ref name collides with an existing ref's case or directory prefix", 409)
  end

  defp case_alias?(left, right) do
    Enum.zip(String.split(left, "/"), String.split(right, "/"))
    |> Enum.reduce_while(false, fn {a, b}, _ ->
      cond do
        String.downcase(a) != String.downcase(b) -> {:halt, false}
        a != b -> {:halt, true}
        true -> {:cont, false}
      end
    end)
  end

  def tag(repository, actor, attrs) do
    unless is_nil(attrs["git"]) or is_map(attrs["git"]),
      do: Error.fail("Invalid Git tag metadata")

    name = name!(attrs["name"])
    target = Changesets.get(repository, attrs["target"]).id
    message = if attrs["message"], do: Flurry.Auth.text!(attrs["message"], "Tag message", 10_000)

    {:ok, result} =
      Repo.transaction(fn ->
        Repositories.lock(repository)
        Repositories.writable!(repository)
        available!(repository, :tag, name)

        existing =
          Repo.one(
            from(t in "tags",
              where: t.repository_id == ^Ecto.UUID.dump!(repository.id) and t.name == ^name,
              select: %{target: t.target, message: t.message, git: t.git, raw: t.raw}
            )
          )

        if existing do
          unless existing.target == target and existing.message == message and
                   (is_nil(attrs["git"]) or existing.git == attrs["git"]["id"]),
                 do: Error.fail("Published tags are immutable; choose a new name", 409)

          %{name: name, target: target, message: message, git: existing.git}
        else
          {git, raw} = annotation(repository, actor, name, target, message, attrs["git"])

          Repo.insert_all("tags", [
            %{
              repository_id: Ecto.UUID.dump!(repository.id),
              name: name,
              target: target,
              message: message,
              git: git,
              raw: raw
            }
          ])

          Flurry.Audit.record(actor, "tag.create", repository, %{name: name, target: target})
          %{name: name, target: target, message: message, git: git}
        end
      end)

    result
  end

  defp annotation(_, _, _, _, nil, nil), do: {nil, nil}

  defp annotation(repository, actor, name, target, message, attrs) do
    target_git = Flurry.Git.View.get(repository, target).git

    raw =
      if attrs do
        unless is_map(attrs) and is_binary(attrs["raw"]) and byte_size(attrs["raw"]) <= 98_304,
          do: Error.fail("Invalid tag annotation")

        raw =
          case Base.decode64(attrs["raw"]) do
            {:ok, raw} -> raw
            _ -> Error.fail("Invalid tag annotation")
          end

        headers = raw |> :binary.split("\n\n") |> hd() |> String.split("\n")

        unless Enum.filter(headers, &String.starts_with?(&1, "object ")) == [
                 "object " <> target_git
               ] and
                 Enum.filter(headers, &String.starts_with?(&1, "type ")) == ["type commit"] and
                 Enum.filter(headers, &String.starts_with?(&1, "tag ")) == ["tag " <> name] and
                 Flurry.Git.View.object_id("tag", raw) == attrs["id"],
               do: Error.fail("Tag object does not match its target or name")

        raw
      else
        identity =
          String.replace(actor.name, ["\r", "\n", "<", ">", <<0>>], " ") <>
            " <#{actor.id}@users.flurry.invalid> #{System.system_time(:second)} +0000"

        "object #{target_git}\ntype commit\ntag #{name}\ntagger #{identity}\n\n#{message}\n"
      end

    {Flurry.Git.View.object_id("tag", raw), raw}
  end
end
