defmodule Flurry.Security.Agents do
  import Ecto.Query
  alias Flurry.{Audit, Auth, Error, Repo, Schema.Agent, Schema.User, Store.Objects}
  alias Flurry.Security.Accounts

  @prefix "fla_"

  def list(owner) do
    Repo.all(
      from(a in Agent,
        join: u in User,
        on: u.id == a.user_id,
        where: a.owner_id == ^owner.id,
        order_by: [desc: a.inserted_at],
        select: {a, u}
      )
    )
    |> Enum.map(fn {agent, user} -> public(agent, user) end)
  end

  def create(owner, attrs) do
    human!(owner)
    Accounts.confirm!(owner, attrs)
    name = Auth.text!(attrs["name"], "Agent name", 80)
    username = Auth.text!(attrs["username"], "Agent username", 40) |> String.downcase()
    validate_username!(username)
    days = days!(attrs["days"] || 90)
    {token, digest, prefix} = credential()
    now = DateTime.utc_now()

    {:ok, {agent, user}} =
      Repo.transaction(fn ->
        user_id = Ecto.UUID.generate()

        user =
          %User{}
          |> Ecto.Changeset.change(
            id: user_id,
            name: name,
            username: username,
            email: "#{user_id}@agents.flurry.invalid",
            password: Auth.encode(Base.url_encode64(:crypto.strong_rand_bytes(48))),
            account_type: "agent",
            private_profile: true,
            hide_activity: true
          )
          |> Ecto.Changeset.unique_constraint(:username)
          |> insert!("This username is already in use")

        agent =
          Repo.insert!(%Agent{
            id: Ecto.UUID.generate(),
            user_id: user.id,
            owner_id: owner.id,
            digest: digest,
            token_prefix: prefix,
            expires_at: DateTime.add(now, days, :day)
          })

        Audit.record(owner, "agent.create", nil, %{username: username})
        {agent, user}
      end)

    Map.put(public(agent, user), :token, token)
  end

  def rotate(owner, id, attrs) do
    human!(owner)
    Accounts.confirm!(owner, attrs)
    {agent, user} = owned!(owner, id)
    days = days!(attrs["days"] || 90)
    {token, digest, prefix} = credential()

    agent =
      agent
      |> Ecto.Changeset.change(
        digest: digest,
        token_prefix: prefix,
        expires_at: DateTime.add(DateTime.utc_now(), days, :day),
        revoked_at: nil,
        last_used_at: nil
      )
      |> Repo.update!()

    user |> Ecto.Changeset.change(disabled: false) |> Repo.update!()
    Audit.record(owner, "agent.rotate", nil, %{username: user.username})
    Map.put(public(agent, %{user | disabled: false}), :token, token)
  end

  def revoke(owner, id, attrs) do
    human!(owner)
    Accounts.confirm!(owner, attrs)
    {agent, user} = owned!(owner, id)

    {:ok, _} =
      Repo.transaction(fn ->
        agent |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update!()
        user |> Ecto.Changeset.change(disabled: true) |> Repo.update!()
        remove_access(user.id)
        Audit.record(owner, "agent.revoke", nil, %{username: user.username})
      end)

    %{ok: true}
  end

  def credential(@prefix <> _ = token) do
    now = DateTime.utc_now()

    case Repo.one(
           from(a in Agent,
             join: u in User,
             on: u.id == a.user_id,
             join: owner in User,
             on: owner.id == a.owner_id,
             where:
               a.digest == ^Objects.digest(token) and a.expires_at > ^now and
                 is_nil(a.revoked_at) and not u.disabled and u.account_type == "agent" and
                 not owner.disabled and owner.account_type == "human",
             select: {a, u}
           )
         ) do
      nil ->
        nil

      {agent, user} ->
        if is_nil(agent.last_used_at) or DateTime.diff(now, agent.last_used_at) > 60 do
          Repo.update_all(from(a in Agent, where: a.id == ^agent.id), set: [last_used_at: now])
        end

        %{user: user, kind: :agent, access: "write", repository_id: nil}
    end
  end

  def credential(_), do: nil

  defp owned!(owner, id) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail("Agent not found", 404)

    Repo.one(
      from(a in Agent,
        join: u in User,
        on: u.id == a.user_id,
        where: a.id == ^id and a.owner_id == ^owner.id,
        select: {a, u}
      )
    ) || Error.fail("Agent not found", 404)
  end

  defp public(agent, user) do
    %{
      id: agent.id,
      user_id: user.id,
      name: user.name,
      username: user.username,
      token_prefix: agent.token_prefix,
      active: is_nil(agent.revoked_at) and not user.disabled,
      expires_at: agent.expires_at,
      last_used_at: agent.last_used_at,
      inserted_at: agent.inserted_at
    }
  end

  defp credential do
    token = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {token, Objects.digest(token), String.slice(token, 0, 10)}
  end

  defp days!(days) do
    unless is_integer(days) and days in 1..365,
      do: Error.fail("Choose an expiry between 1 and 365 days")

    days
  end

  defp validate_username!(username) do
    unless Regex.match?(~r/\A[a-z0-9][a-z0-9.]*\z/, username),
      do: Error.fail("Agent usernames use lowercase letters, numbers, and dots")
  end

  defp human!(%User{account_type: "human"}), do: :ok
  defp human!(_), do: Error.fail("Agent accounts cannot manage other agents", 403)

  defp insert!(changeset, message) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, _} -> Error.fail(message, 409)
    end
  end

  defp remove_access(user_id) do
    id = Ecto.UUID.dump!(user_id)
    Repo.delete_all(from(m in "members", where: m.user_id == ^id))
    Repo.delete_all(from(m in "teammembers", where: m.user_id == ^id))
    Repo.delete_all(from(m in "organizationmembers", where: m.user_id == ^id))
  end
end
