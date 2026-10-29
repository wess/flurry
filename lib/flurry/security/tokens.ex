defmodule Flurry.Security.Tokens do
  import Ecto.Query
  alias Flurry.{Auth, Repo, Error, Audit, Store.Objects}
  alias Flurry.Engine.Repositories

  def list(user),
    do:
      Repo.all(
        from(t in "tokens",
          where: t.user_id == ^Ecto.UUID.dump!(user.id),
          order_by: [desc: t.inserted_at],
          select: %{
            id: type(t.id, Ecto.UUID),
            name: t.name,
            access: t.access,
            repository_id: type(t.repository_id, Ecto.UUID),
            inserted_at: t.inserted_at,
            expires_at: t.expires_at
          }
        )
      )

  def create(user, attrs) do
    Flurry.Security.Accounts.confirm!(user, attrs)
    name = Auth.text!(attrs["name"], "Token name", 80)
    access = attrs["access"]
    unless access in ["read", "write"], do: Error.fail("Choose read or write access")
    days = attrs["days"]

    unless is_integer(days) and days in 1..365,
      do: Error.fail("Choose an expiry between 1 and 365 days")

    repository =
      if attrs["repository_id"] not in [nil, ""],
        do: Repositories.get(user, attrs["repository_id"])

    token = "flr_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    id = Ecto.UUID.generate()

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.insert_all("tokens", [
          %{
            id: Ecto.UUID.dump!(id),
            user_id: Ecto.UUID.dump!(user.id),
            digest: Objects.digest(token),
            name: name,
            access: access,
            repository_id: if(repository, do: Ecto.UUID.dump!(repository.id)),
            inserted_at: DateTime.utc_now(),
            expires_at: DateTime.add(DateTime.utc_now(), days, :day)
          }
        ])

        Audit.record(user, "token.create", nil, %{name: name, access: access})
      end)

    %{id: id, token: token}
  end

  def revoke(user, id) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail("Token not found", 404)

    Repo.delete_all(
      from(t in "tokens",
        where: t.id == ^Ecto.UUID.dump!(id) and t.user_id == ^Ecto.UUID.dump!(user.id)
      )
    )

    Audit.record(user, "token.revoke")
  end
end
