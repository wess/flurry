defmodule Flurry.Profiles do
  import Ecto.Query
  alias Flurry.{Auth, Error, Repo}
  alias Flurry.Schema.{User, Repository, Changeset}
  alias Flurry.Engine.Repositories

  def get(username, viewer) do
    user = Repo.get_by(User, username: username) || Error.fail("User not found", 404)
    own = not is_nil(viewer) and viewer.id == user.id
    if user.disabled or (user.private_profile and not own), do: Error.fail("User not found", 404)

    repositories =
      Repo.all(
        from(r in Repository,
          where:
            r.owner_id == ^user.id and is_nil(r.deleted_at) and
              (r.visibility == "public" or ^(!!own)),
          order_by: r.name
        )
      )
      |> Enum.map(&Repositories.public/1)

    ids = Enum.map(repositories, & &1.id)

    activity =
      Repo.all(
        from(c in Changeset,
          where: c.author_id == ^user.id and c.repository_id in ^ids,
          order_by: [desc: c.inserted_at],
          limit: 20
        )
      )
      |> Enum.map(fn c ->
        %{
          id: c.id,
          message: c.message,
          repository_id: c.repository_id,
          inserted_at: c.inserted_at
        }
      end)

    Map.merge(Auth.public(user), %{
      repositories: repositories,
      activity: if(user.hide_activity and not own, do: [], else: activity)
    })
  end

  def update(user, attrs) do
    name = Auth.text!(attrs["name"], "Display name", 80)

    fields =
      Enum.map([{"bio", 300}, {"location", 100}, {"website", 300}], fn {key, max} ->
        value = attrs[key] || ""

        unless is_binary(value) and String.valid?(value) and byte_size(value) <= max,
          do: Error.fail("#{key} must be at most #{max} bytes")

        {String.to_existing_atom(key), String.trim(value)}
      end)

    website = Keyword.fetch!(fields, :website)

    if website != "" do
      uri = URI.parse(website)

      unless uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "",
        do: Error.fail("Website must be an http or https URL")
    end

    result = user |> Ecto.Changeset.change([name: name] ++ fields) |> Repo.update!()
    Flurry.Audit.record(user, "profile.update")
    result
  end
end
