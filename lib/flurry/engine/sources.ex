defmodule Flurry.Engine.Sources do
  import Ecto.Query
  alias Flurry.{Error, Repo}
  alias Flurry.Schema.Source
  alias Flurry.Engine.{Repositories, SourceConnections}
  alias Flurry.Git.{Remote, Worker}

  def create(user, attrs) do
    remote = Remote.parse(attrs["url"], attrs["branch"])
    {connection, saved} = SourceConnections.resolve(user, attrs["connection_id"], remote.host)
    credentials = prefer(Remote.credentials(attrs), saved)
    attrs = Map.put(attrs, "name", repository_name(attrs["name"], remote.url))

    {:ok, repository} =
      Repo.transaction(fn ->
        repository = Repositories.create(user, attrs)

        Repo.insert!(%Source{
          repository_id: repository.id,
          url: remote.url,
          branch: remote.branch,
          source_connection_id: connection && connection.id
        })

        repository
      end)

    start(repository, user, "import", credentials, nil)
    repository
  end

  def get(repository), do: Repo.get(Source, repository.id)

  def transfer(repository, user, operation, attrs) when operation in ["pull", "push", "import"] do
    source = get(repository) || Error.fail("This repository has no linked source", 404)
    remote = Remote.parse(source.url, source.branch)

    {connection, saved} =
      SourceConnections.resolve(
        user,
        attrs["connection_id"] || source.source_connection_id,
        remote.host
      )

    credentials = prefer(Remote.credentials(attrs), saved)

    head =
      if operation == "push" do
        head = attrs["head"]

        unless is_binary(head) and head == Repositories.head(repository),
          do: Error.fail("Main changed; refresh the repository before pushing", 409)

        head
      end

    start(repository, user, operation, credentials, head, connection && connection.id)
    public(get(repository))
  end

  def public(nil), do: nil

  def public(source) do
    %{
      url: source.url,
      branch: source.branch,
      status: source.status,
      operation: source.operation,
      error: source.error,
      message: source.message,
      commit: source.commit,
      review_id: source.review_id,
      synced_at: source.synced_at,
      connection_id: source.source_connection_id
    }
  end

  def complete_review(review) do
    case Repo.one(from(s in Source, where: s.review_id == ^review.id)) do
      nil ->
        :ok

      source ->
        source
        |> Ecto.Changeset.change(
          commit: source.incoming_commit,
          root: source.incoming_root,
          modes: source.incoming_modes,
          review_id: nil,
          incoming_commit: nil,
          incoming_root: nil,
          incoming_modes: nil,
          synced_at: DateTime.utc_now(),
          message: "Upstream updates landed"
        )
        |> Repo.update!()
    end
  end

  defp start(repository, user, operation, credentials, head, connection_id \\ nil) do
    Repositories.writable!(repository)
    job = Ecto.UUID.generate()

    {:ok, source} =
      Repo.transaction(fn ->
        Repositories.lock(repository)
        Repositories.writable!(repository)

        source =
          Repo.one(
            from(s in Source, where: s.repository_id == ^repository.id, lock: "FOR UPDATE")
          ) || Error.fail("This repository has no linked source", 404)

        if source.status == "running", do: Error.fail("A transfer is already running", 409)

        if source.review_id,
          do:
            Error.fail("Land the existing upstream review before starting another transfer", 409)

        if operation == "import" and (source.commit || Repositories.head(repository)),
          do: Error.fail("This repository has already been imported; use Pull updates", 409)

        if operation != "import" and is_nil(source.commit),
          do: Error.fail("Complete the initial import first", 409)

        source
        |> Ecto.Changeset.change(
          status: "running",
          operation: operation,
          job: job,
          requested_head: head,
          error: nil,
          message: nil,
          source_connection_id: connection_id || source.source_connection_id
        )
        |> Repo.update!()
      end)

    case Task.Supervisor.start_child(Flurry.Transfers, fn ->
           Worker.run(repository, user, source, credentials)
         end) do
      {:ok, _} -> :ok
      {:error, _} -> Worker.fail(source, "The transfer queue is busy; try again shortly")
    end
  end

  defp prefer(%{token: token} = supplied, _saved) when token != "", do: supplied
  defp prefer(_supplied, saved), do: saved

  defp repository_name(value, _url) when is_binary(value) and value != "", do: value

  defp repository_name(_, url) do
    url
    |> URI.parse()
    |> Map.fetch!(:path)
    |> String.split("/", trim: true)
    |> List.last()
    |> String.trim_trailing(".git")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9.]+/, ".")
    |> String.trim(".")
    |> String.slice(0, 80)
    |> case do
      "" -> Error.fail("Enter a repository name")
      name -> name
    end
  end
end
