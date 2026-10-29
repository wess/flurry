defmodule Flurry.Engine.Settings do
  import Ecto.Query
  alias Flurry.{Repo, Auth, Audit, Error, Schema.User, Schema.Repository, Schema.Source}
  alias Flurry.Engine.Repositories

  def update(repository, user, attrs) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repositories.lock(repository)
        current = Repositories.get(user, repository.id, :manage)
        name = Auth.text!(attrs["name"] || current.name, "Repository name", 80)

        unless Regex.match?(~r/\A[a-z0-9][a-z0-9.]*\z/, name),
          do: Error.fail("Repository names use lowercase letters, numbers, and dots")

        description = Map.get(attrs, "description", current.description)
        visibility = attrs["visibility"] || current.visibility

        unless is_binary(description) and byte_size(description) <= 500 and
                 visibility in ["private", "public"],
               do: Error.fail("Invalid repository settings")

        if visibility == "public" and not Flurry.Instance.get().allow_public,
          do: Error.fail("Public repositories are disabled")

        if visibility != current.visibility, do: Flurry.Security.Accounts.confirm!(user, attrs)
        self_approval = Map.get(attrs, "allow_self_approval", current.allow_self_approval)
        unless is_boolean(self_approval), do: Error.fail("Self approval must be true or false")

        required_approvals = Map.get(attrs, "required_approvals", current.required_approvals)

        unless is_integer(required_approvals) and required_approvals in 1..20,
          do: Error.fail("Required approvals must be between 1 and 20")

        policy = Flurry.Engine.Policies.settings(attrs, current)
        review = review_settings(attrs, current)

        changeset =
          current
          |> Ecto.Changeset.change(
            name: name,
            description: description,
            visibility: visibility,
            allow_self_approval: self_approval,
            required_approvals: required_approvals,
            required_statuses: policy.required_statuses,
            protected_paths: policy.protected_paths,
            push_allowlist: policy.push_allowlist,
            require_signed_commits: policy.require_signed_commits,
            review_trigger: review.trigger,
            review_profiles: review.profiles,
            review_status_context: review.status_context
          )
          |> Ecto.Changeset.unique_constraint(:name,
            name:
              if(current.organization_id,
                do: :repositories_organization_name_index,
                else: :repositories_user_name_index
              )
          )

        result =
          case Repo.update(changeset) do
            {:ok, result} -> result
            {:error, _} -> Error.fail("A repository with this name already exists", 409)
          end

        Audit.record(user, "repository.settings", repository, %{
          visibility: visibility,
          allow_self_approval: self_approval,
          required_approvals: required_approvals,
          required_statuses: policy.required_statuses,
          protected_paths: policy.protected_paths,
          push_allowlist: policy.push_allowlist,
          require_signed_commits: policy.require_signed_commits,
          review_trigger: review.trigger,
          review_profiles: review.profiles,
          review_status_context: review.status_context
        })

        result
      end)

    result
  end

  defp review_settings(attrs, current) do
    trigger = Map.get(attrs, "review_trigger", current.review_trigger)

    unless trigger in ["manual", "review_opened", "every_revision"],
      do: Error.fail("Choose a valid automated review trigger")

    allowed = ["correctness", "security", "regression", "edge_case", "contract"]
    profiles = Map.get(attrs, "review_profiles", current.review_profiles)

    unless is_list(profiles) and length(profiles) in 1..5 and
             Enum.all?(profiles, &(&1 in allowed)),
           do: Error.fail("Choose between 1 and 5 review profiles")

    context =
      review_context!(Map.get(attrs, "review_status_context", current.review_status_context))

    %{trigger: trigger, profiles: Enum.uniq(profiles), status_context: context}
  end

  defp review_context!(nil), do: nil
  defp review_context!(""), do: nil

  defp review_context!(value) do
    value = Auth.text!(value, "Review status context", 100)

    unless Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9 ._\/-]*\z/, value),
      do: Error.fail("Review status context contains unsupported characters")

    value
  end

  def lifecycle(repository, user, attrs) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repositories.lock(repository)
        repository = Repositories.get(user, repository.id, :manage)
        idle!(repository)
        action = attrs["action"]

        fields =
          case action do
            "archive" ->
              [archived: true]

            "unarchive" ->
              [archived: false]

            "remove" ->
              Flurry.Security.Accounts.confirm!(user, attrs)

              unless attrs["confirm"] == repository.name,
                do: Error.fail("Type the repository name to remove it")

              [deleted_at: DateTime.utc_now(), archived: true, visibility: "private"]

            _ ->
              Error.fail("Unknown repository action")
          end

        result = repository |> Ecto.Changeset.change(fields) |> Repo.update!()
        Audit.record(user, "repository." <> action, repository)
        result
      end)

    result
  end

  def removed(user) do
    Repo.all(
      from(r in Repository,
        where: r.owner_id == ^user.id and not is_nil(r.deleted_at),
        order_by: [desc: r.deleted_at]
      )
    )
    |> Enum.map(&Map.take(&1, [:id, :name, :deleted_at]))
  end

  def restore(user, id) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail("Repository not found", 404)

    repository =
      Repo.one(
        from(r in Repository,
          where: r.id == ^id and r.owner_id == ^user.id and not is_nil(r.deleted_at)
        )
      ) || Error.fail("Repository not found", 404)

    {:ok, _} =
      Repo.transaction(fn ->
        Repositories.lock(repository)
        current = Repo.get!(Repository, repository.id)
        unless current.deleted_at, do: Error.fail("Repository is already restored", 409)
        Flurry.Quota.repository!(user)

        current
        |> Ecto.Changeset.change(deleted_at: nil, archived: true, visibility: "private")
        |> Repo.update!()

        Audit.record(user, "repository.restore", repository)
      end)
  end

  def members(repository) do
    Repo.all(
      from(m in "members",
        join: u in User,
        on: u.id == m.user_id,
        where: m.repository_id == ^Ecto.UUID.dump!(repository.id),
        order_by: u.username,
        select: %{username: u.username, name: u.name, role: m.role}
      )
    )
  end

  def member(repository, actor, attrs) do
    Repositories.get(actor, repository.id, :manage)
    username = Auth.text!(attrs["username"], "Username", 40)
    target = Repo.get_by(User, username: username) || Error.fail("User not found", 404)

    if target.id == repository.owner_id or target.disabled,
      do: Error.fail("Choose an active collaborator other than the owner")

    role = attrs["role"]

    unless role in ["read", "write", "maintain", "remove"],
      do: Error.fail("Choose a collaborator role")

    {:ok, _} =
      Repo.transaction(fn ->
        Repositories.lock(repository)
        Repositories.writable!(repository)

        if role == "remove" do
          Repo.delete_all(
            from(m in "members",
              where:
                m.repository_id == ^Ecto.UUID.dump!(repository.id) and
                  m.user_id == ^Ecto.UUID.dump!(target.id)
            )
          )
        else
          Repo.insert_all(
            "members",
            [
              %{
                repository_id: Ecto.UUID.dump!(repository.id),
                user_id: Ecto.UUID.dump!(target.id),
                role: role
              }
            ],
            on_conflict: [set: [role: role]],
            conflict_target: [:repository_id, :user_id]
          )
        end

        Audit.record(actor, "repository.member", repository, %{username: username, role: role})
      end)
  end

  def unlink(repository, actor, attrs) do
    Flurry.Security.Accounts.confirm!(actor, attrs)

    {:ok, _} =
      Repo.transaction(fn ->
        Repositories.lock(repository)
        Repositories.get(actor, repository.id, :manage)
        idle!(repository)
        Repo.delete_all(from(s in Source, where: s.repository_id == ^repository.id))
        Audit.record(actor, "source.unlink", repository)
      end)
  end

  defp idle!(repository) do
    if Repo.exists?(
         from(s in Source, where: s.repository_id == ^repository.id and s.status == "running")
       ),
       do: Error.fail("Wait for the active source transfer to finish", 409)
  end
end
