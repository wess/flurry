defmodule Flurry.Audit do
  import Ecto.Query
  alias Flurry.Repo

  def record(user, event, repository \\ nil, details \\ %{}) do
    Repo.insert_all("audit", [
      %{
        actor_id: if(user, do: Ecto.UUID.dump!(user.id)),
        repository_id: if(repository, do: Ecto.UUID.dump!(repository.id)),
        event: event,
        details: details,
        inserted_at: DateTime.utc_now()
      }
    ])
  end

  def list(user, repository \\ nil) do
    query =
      from(a in "audit",
        order_by: [desc: a.id],
        limit: 100,
        select: %{id: a.id, event: a.event, details: a.details, inserted_at: a.inserted_at}
      )

    query =
      cond do
        repository -> from(a in query, where: a.repository_id == ^Ecto.UUID.dump!(repository.id))
        user.admin -> query
        true -> from(a in query, where: a.actor_id == ^Ecto.UUID.dump!(user.id))
      end

    Repo.all(query)
  end
end
