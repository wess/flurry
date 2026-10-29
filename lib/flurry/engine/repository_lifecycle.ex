defmodule Flurry.Engine.RepositoryLifecycle do
  import Ecto.Query

  alias Flurry.{Audit, Auth, Error, Repo}
  alias Flurry.Engine.{Changesets, Organizations, Refs, Repositories}
  alias Flurry.Schema.{Changeset, Organization, Repository, RepositoryTransfer, User}

  @history_limit 10_000

  def duplicate(source, user, attrs) do
    name = Auth.text!(attrs["name"], "Repository name", 80)

    {:ok, repository} =
      Repo.transaction(fn ->
        repository =
          Repositories.create(user, %{
            "name" => name,
            "description" => Map.get(attrs, "description", source.description),
            "visibility" => attrs["visibility"] || "private",
            "organization_id" => attrs["organization_id"]
          })

        repository =
          repository
          |> Ecto.Changeset.change(
            fork_of_id: source.id,
            allow_self_approval: source.allow_self_approval,
            required_approvals: source.required_approvals,
            required_statuses: source.required_statuses,
            protected_paths: source.protected_paths,
            require_signed_commits: source.require_signed_commits,
            push_allowlist: []
          )
          |> Repo.update!()

        changes =
          Repo.all(
            from(c in Changeset,
              where: c.repository_id == ^source.id,
              order_by: [asc: c.inserted_at, asc: c.id],
              limit: ^(@history_limit + 1)
            )
          )

        if length(changes) > @history_limit,
          do: Error.fail("Duplicate repositories with at most #{@history_limit} revisions", 413)

        mapping = copy_changes(source, repository, changes, %{})
        copy_refs(source, repository, user, mapping)
        Audit.record(user, "repository.duplicate", repository, %{source_id: source.id})
        repository
      end)

    repository
  end

  def request_transfer(repository, actor, attrs) do
    Flurry.Security.Accounts.confirm!(actor, attrs)
    {target_user, target_organization} = transfer_target(actor, attrs)

    if target_user && target_user.id == actor.id && is_nil(repository.organization_id),
      do: Error.fail("Repository is already owned by this user", 409)

    transfer =
      %RepositoryTransfer{}
      |> Ecto.Changeset.change(
        id: Ecto.UUID.generate(),
        repository_id: repository.id,
        sender_id: actor.id,
        target_user_id: target_user && target_user.id,
        target_organization_id: target_organization && target_organization.id,
        status: "pending",
        expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
      )
      |> Ecto.Changeset.unique_constraint(:repository_id,
        name: :repository_transfers_pending_index
      )

    case Repo.insert(transfer) do
      {:ok, transfer} ->
        Audit.record(actor, "repository.transfer.request", repository, transfer_public(transfer))

        if transfer.target_user_id do
          Flurry.Engine.Notifications.notify(
            transfer.target_user_id,
            "repository.transfer",
            "Repository transfer requested",
            actor: actor,
            repository: repository,
            url: "/settings/transfers"
          )
        end

        transfer_public(transfer)

      {:error, _} ->
        Error.fail("This repository already has a pending transfer", 409)
    end
  end

  def transfers(user) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(t in RepositoryTransfer,
        where: t.status == "pending" and t.expires_at <= ^now
      ),
      set: [status: "expired", updated_at: now]
    )

    organization_ids =
      Repo.all(
        from(m in "organizationmembers",
          where: m.user_id == ^Ecto.UUID.dump!(user.id) and m.role in ["owner", "admin"],
          select: type(m.organization_id, Ecto.UUID)
        )
      )

    Repo.all(
      from(t in RepositoryTransfer,
        where:
          t.status == "pending" and
            (t.sender_id == ^user.id or t.target_user_id == ^user.id or
               t.target_organization_id in ^organization_ids),
        order_by: [desc: t.inserted_at]
      )
    )
    |> Enum.map(&transfer_public/1)
  end

  def accept_transfer(user, id) do
    {:ok, repository} =
      Repo.transaction(fn ->
        transfer = transfer!(id, lock: true)
        ensure_pending!(transfer)
        repository = Repo.get!(Repository, transfer.repository_id)
        Repositories.lock(repository)
        authorize_target!(transfer, user)
        Flurry.Quota.repository!(user)

        organization =
          if transfer.target_organization_id,
            do: Repo.get!(Organization, transfer.target_organization_id)

        conflict_query =
          if organization do
            from(r in Repository,
              where:
                r.id != ^repository.id and r.name == ^repository.name and
                  r.organization_id == ^organization.id
            )
          else
            from(r in Repository,
              where:
                r.id != ^repository.id and r.name == ^repository.name and
                  is_nil(r.organization_id) and r.owner_id == ^user.id
            )
          end

        conflict = Repo.exists?(conflict_query)

        if conflict,
          do: Error.fail("The destination already has a repository with this name", 409)

        Repo.delete_all(
          from(x in "teamrepositories",
            where: x.repository_id == ^Ecto.UUID.dump!(repository.id)
          )
        )

        repository =
          repository
          |> Ecto.Changeset.change(
            owner_id: user.id,
            organization_id: organization && organization.id,
            visibility: "private",
            push_allowlist: []
          )
          |> Repo.update!()

        transfer |> Ecto.Changeset.change(status: "accepted") |> Repo.update!()
        Audit.record(user, "repository.transfer.accept", repository, %{transfer_id: transfer.id})
        repository
      end)

    Repositories.public(repository)
  end

  def cancel_transfer(user, id) do
    transfer = transfer!(id)
    ensure_pending!(transfer)

    unless transfer.sender_id == user.id or transfer.target_user_id == user.id or
             target_manager?(transfer, user),
           do: Error.fail("Transfer not found", 404)

    transfer |> Ecto.Changeset.change(status: "cancelled") |> Repo.update!()
    %{ok: true}
  end

  defp copy_changes(_source, _target, [], mapping), do: mapping

  defp copy_changes(source, target, remaining, mapping) do
    {ready, pending} =
      Enum.split_with(remaining, fn change ->
        known?(change.parent_id, mapping) and known?(change.merge_parent_id, mapping)
      end)

    if ready == [], do: Error.fail("Repository history contains unresolved parents", 500)

    mapping =
      Enum.reduce(ready, mapping, fn change, acc ->
        parent = mapped(change.parent_id, acc)
        merge = mapped(change.merge_parent_id, acc)
        provenance = mapped(change.source_id, acc)
        root = Changesets.root(source, change.id)

        copied =
          Changesets.insert(
            target,
            change.author_id,
            parent,
            provenance,
            change.message,
            change.changes,
            root,
            merge
          )

        Map.put(acc, change.id, copied.id)
      end)

    copy_changes(source, target, pending, mapping)
  end

  defp copy_refs(source, target, user, mapping) do
    refs = Refs.list(source)

    Enum.each(refs.branches, fn ref ->
      head = mapped(ref.head, mapping)

      Repo.insert_all(
        "refs",
        [%{repository_id: Ecto.UUID.dump!(target.id), name: ref.name, head: head}],
        on_conflict: [set: [head: head]],
        conflict_target: [:repository_id, :name]
      )
    end)

    Enum.each(refs.tags, fn tag ->
      Refs.tag(target, user, %{
        "name" => tag.name,
        "target" => mapped(tag.target, mapping),
        "message" => tag.message
      })
    end)
  end

  defp transfer_target(_actor, %{"username" => username}) when is_binary(username) do
    target = Repo.get_by(User, username: Auth.text!(username, "Username", 80))
    if is_nil(target) or target.disabled, do: Error.fail("User not found", 404)
    {target, nil}
  end

  defp transfer_target(actor, %{"organization_id" => id}) when is_binary(id),
    do: {nil, Organizations.get(actor, id, :manage)}

  defp transfer_target(_, _),
    do: Error.fail("Choose one destination user or organization")

  defp authorize_target!(%{target_user_id: id}, %{id: id}), do: :ok

  defp authorize_target!(transfer, user) do
    if target_manager?(transfer, user), do: :ok, else: Error.fail("Transfer not found", 404)
  end

  defp target_manager?(%{target_organization_id: nil}, _), do: false

  defp target_manager?(transfer, user) do
    organization = Repo.get(Organization, transfer.target_organization_id)
    organization && Organizations.permitted?(organization, user, :manage)
  end

  defp transfer!(id, options \\ []) do
    query = from(t in RepositoryTransfer, where: t.id == ^id)
    query = if options[:lock], do: from(t in query, lock: "FOR UPDATE"), else: query
    Repo.one(query) || Error.fail("Transfer not found", 404)
  end

  defp ensure_pending!(transfer) do
    if transfer.status != "pending", do: Error.fail("Transfer is no longer pending", 409)

    if DateTime.compare(transfer.expires_at, DateTime.utc_now()) != :gt do
      transfer |> Ecto.Changeset.change(status: "expired") |> Repo.update!()
      Error.fail("Transfer expired", 409)
    end
  end

  defp transfer_public(transfer) do
    repository = Repo.get!(Repository, transfer.repository_id)

    %{
      id: transfer.id,
      repository: %{id: repository.id, name: repository.name},
      sender: user_public(transfer.sender_id),
      target_user: if(transfer.target_user_id, do: user_public(transfer.target_user_id)),
      target_organization:
        if(transfer.target_organization_id,
          do:
            Repo.get!(Organization, transfer.target_organization_id)
            |> Map.take([:id, :name, :slug])
        ),
      status: transfer.status,
      expires_at: transfer.expires_at,
      inserted_at: transfer.inserted_at
    }
  end

  defp user_public(id), do: Repo.get!(User, id) |> Map.take([:id, :name, :username])
  defp known?(nil, _), do: true
  defp known?(id, mapping), do: Map.has_key?(mapping, id)
  defp mapped(nil, _), do: nil
  defp mapped(id, mapping), do: Map.get(mapping, id)
end
