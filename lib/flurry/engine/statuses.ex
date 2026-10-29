defmodule Flurry.Engine.Statuses do
  import Ecto.Query
  alias Flurry.{Auth, Error, Repo}
  alias Flurry.Engine.{Repositories, Webhooks}
  alias Flurry.Schema.{Changeset, CommitStatus}

  @states ["pending", "success", "failure", "error"]

  def put(repository, actor, changeset_id, attrs) do
    unless Repositories.permitted?(repository, actor, :write),
      do: Error.fail("Write access required", 403)

    unless Repo.exists?(
             from(c in Changeset,
               where: c.id == ^changeset_id and c.repository_id == ^repository.id
             )
           ),
           do: Error.fail("Revision not found", 404)

    context = Auth.text!(attrs["context"], "Status context", 100)

    unless Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9 ._\/-]*\z/, context),
      do: Error.fail("Status context contains unsupported characters")

    state = attrs["state"]
    unless state in @states, do: Error.fail("Choose a valid status state")
    description = description!(attrs["description"] || "")
    target_url = target_url!(attrs["target_url"])

    {:ok, status} =
      Repo.transaction(fn ->
        status =
          Repo.one(
            from(s in CommitStatus,
              where:
                s.repository_id == ^repository.id and s.changeset_id == ^changeset_id and
                  s.context == ^context,
              lock: "FOR UPDATE"
            )
          ) ||
            %CommitStatus{
              id: Ecto.UUID.generate(),
              repository_id: repository.id,
              changeset_id: changeset_id,
              creator_id: actor.id,
              context: context
            }

        status =
          status
          |> Ecto.Changeset.change(
            creator_id: actor.id,
            state: state,
            description: description,
            target_url: target_url
          )
          |> Repo.insert_or_update!()

        Webhooks.emit(repository, "status.updated", public(status))
        status
      end)

    public(status)
  end

  def list(repository, changeset_id) do
    Repo.all(
      from(s in CommitStatus,
        where: s.repository_id == ^repository.id and s.changeset_id == ^changeset_id,
        order_by: [asc: s.context]
      )
    )
    |> Enum.map(&public/1)
  end

  def summary(repository, changeset_id) do
    statuses = list(repository, changeset_id)
    states = Enum.map(statuses, & &1.state)

    overall =
      cond do
        Enum.any?(states, &(&1 in ["failure", "error"])) -> "failure"
        "pending" in states -> "pending"
        "success" in states -> "success"
        true -> nil
      end

    %{state: overall, statuses: statuses}
  end

  def public(status) do
    %{
      id: status.id,
      changeset_id: status.changeset_id,
      creator_id: status.creator_id,
      context: status.context,
      state: status.state,
      description: status.description,
      target_url: status.target_url,
      inserted_at: status.inserted_at,
      updated_at: status.updated_at
    }
  end

  defp target_url!(nil), do: nil
  defp target_url!(""), do: nil

  defp target_url!(value) when is_binary(value) and byte_size(value) <= 2_000 do
    uri = URI.parse(value)

    if uri.scheme == "https" and is_binary(uri.host) and is_nil(uri.userinfo) and
         is_nil(uri.fragment),
       do: value,
       else: Error.fail("Status target URLs must use HTTPS")
  end

  defp target_url!(_), do: Error.fail("Status target URL is too long")

  defp description!(value) do
    unless is_binary(value) and String.valid?(value) and byte_size(value) <= 500,
      do: Error.fail("Status description must be at most 500 bytes")

    String.trim(value)
  end
end
