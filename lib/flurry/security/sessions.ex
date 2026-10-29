defmodule Flurry.Security.Sessions do
  import Ecto.Query
  alias Flurry.{Repo, Auth, Error, Audit, Store.Objects}
  alias Flurry.Security.Agents

  def issue(user, label \\ "Sign-in session") do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now = DateTime.utc_now()

    Repo.insert_all("sessions", [
      %{
        id: Objects.digest(token),
        user_id: Ecto.UUID.dump!(user.id),
        public_id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        inserted_at: now,
        label: String.slice(label || "Sign-in session", 0, 160),
        expires_at: DateTime.add(now, 7, :day)
      }
    ])

    token
  end

  def list(user, token) do
    digest = Objects.digest(token || "")

    Repo.all(
      from(s in "sessions",
        where: s.user_id == ^Ecto.UUID.dump!(user.id) and s.expires_at > ^DateTime.utc_now(),
        order_by: [desc: s.inserted_at],
        select: %{
          id: type(s.public_id, Ecto.UUID),
          label: s.label,
          inserted_at: s.inserted_at,
          expires_at: s.expires_at,
          current: s.id == ^digest
        }
      )
    )
  end

  def revoke(user, id) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail("Session not found", 404)

    Repo.delete_all(
      from(s in "sessions",
        where: s.user_id == ^Ecto.UUID.dump!(user.id) and s.public_id == ^Ecto.UUID.dump!(id)
      )
    )

    Audit.record(user, "session.revoke")
  end

  def revoke_others(user, token) do
    Repo.delete_all(
      from(s in "sessions",
        where: s.user_id == ^Ecto.UUID.dump!(user.id) and s.id != ^Objects.digest(token)
      )
    )

    Audit.record(user, "session.revokeothers")
  end

  def revoke_all(user) do
    for table <- ["sessions", "tokens"],
        do: Repo.delete_all(from(s in table, where: s.user_id == ^Ecto.UUID.dump!(user.id)))
  end

  def rotate(user) do
    revoke_all(user)
    {Repo.get!(Flurry.Schema.User, user.id), issue(user)}
  end

  def credential(token, bearer?) do
    case Auth.resolve(token) do
      nil -> if bearer?, do: token_user(token) || Agents.credential(token), else: nil
      user -> %{user: user, kind: :session, access: "write", repository_id: nil}
    end
  end

  defp token_user("flr_" <> _ = token) do
    now = DateTime.utc_now()

    case Repo.one(
           from(t in "tokens",
             where: t.digest == ^Objects.digest(token) and t.expires_at > ^now,
             select: %{
               user_id: type(t.user_id, Ecto.UUID),
               access: t.access,
               repository_id: type(t.repository_id, Ecto.UUID)
             }
           )
         ) do
      nil ->
        nil

      record ->
        user = Repo.get!(Flurry.Schema.User, record.user_id)

        unless user.disabled,
          do: %{
            user: user,
            kind: :token,
            access: record.access,
            repository_id: record.repository_id
          }
    end
  end

  defp token_user(_), do: nil
end
