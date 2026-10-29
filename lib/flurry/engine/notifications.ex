defmodule Flurry.Engine.Notifications do
  import Ecto.Query

  alias Flurry.{Auth, Error, Repo}
  alias Flurry.Schema.{Notification, User}

  def notify(user_id, kind, title, options \\ []) do
    actor = options[:actor]

    if is_nil(actor) or actor.id != user_id do
      %Notification{}
      |> Ecto.Changeset.change(
        id: Ecto.UUID.generate(),
        user_id: user_id,
        actor_id: actor && actor.id,
        repository_id: options[:repository] && options[:repository].id,
        kind: Auth.text!(kind, "Notification kind", 80),
        title: Auth.text!(title, "Notification title", 200),
        body: text(options[:body], 2_000),
        url: url(options[:url]),
        data: options[:data] || %{}
      )
      |> Repo.insert!()
    end
  end

  def list(user, unread_only \\ false) do
    query =
      from(n in Notification,
        where: n.user_id == ^user.id,
        order_by: [desc: n.inserted_at],
        limit: 100
      )

    query = if unread_only, do: from(n in query, where: is_nil(n.read_at)), else: query
    values = Repo.all(query) |> Enum.map(&public/1)

    unread =
      Repo.aggregate(
        from(n in Notification, where: n.user_id == ^user.id and is_nil(n.read_at)),
        :count
      )

    %{notifications: values, unread: unread}
  end

  def read(user, id) do
    notification =
      Repo.get_by(Notification, id: id, user_id: user.id) ||
        Error.fail("Notification not found", 404)

    notification
    |> Ecto.Changeset.change(read_at: notification.read_at || DateTime.utc_now())
    |> Repo.update!()
    |> public()
  end

  def read_all(user) do
    Repo.update_all(from(n in Notification, where: n.user_id == ^user.id and is_nil(n.read_at)),
      set: [read_at: DateTime.utc_now()]
    )

    %{ok: true}
  end

  defp public(notification) do
    actor = if notification.actor_id, do: Repo.get(User, notification.actor_id)

    Map.merge(
      Map.take(notification, [
        :id,
        :repository_id,
        :kind,
        :title,
        :body,
        :url,
        :data,
        :read_at,
        :inserted_at
      ]),
      %{actor: if(actor, do: Map.take(actor, [:id, :name, :username]))}
    )
  end

  defp text(nil, _), do: ""
  defp text(value, limit) when is_binary(value) and byte_size(value) <= limit, do: value
  defp text(_, _), do: Error.fail("Notification body is invalid")
  defp url(nil), do: nil
  defp url(value) when is_binary(value) and byte_size(value) <= 500, do: value
  defp url(_), do: Error.fail("Notification URL is invalid")
end
