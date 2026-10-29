defmodule Flurry.Engine.Policies do
  import Ecto.Query
  alias Flurry.{Auth, Error, Repo}
  alias Flurry.Engine.{Changesets, Repositories, Statuses}
  alias Flurry.Schema.{Codeowner, ReviewDecision, User}

  def codeowners(repository) do
    Repo.all(
      from(c in Codeowner,
        join: u in User,
        on: u.id == c.user_id,
        where: c.repository_id == ^repository.id,
        order_by: [asc: c.pattern, asc: u.username],
        select: %{
          id: c.id,
          pattern: c.pattern,
          user: %{id: u.id, name: u.name, username: u.username}
        }
      )
    )
  end

  def add_codeowner(repository, actor, attrs) do
    unless Repositories.permitted?(repository, actor, :manage),
      do: Error.fail("Owner access required", 403)

    pattern = pattern!(attrs["pattern"])
    username = Auth.text!(attrs["username"], "Username", 80)
    user = Repo.get_by(User, username: username) || Error.fail("User not found", 404)

    unless Repositories.permitted?(repository, user, :read),
      do: Error.fail("Code owners must have repository access", 409)

    %Codeowner{
      id: Ecto.UUID.generate(),
      repository_id: repository.id,
      pattern: pattern,
      user_id: user.id
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint([:repository_id, :pattern, :user_id])
    |> case do
      changeset ->
        case Repo.insert(changeset) do
          {:ok, _} ->
            %{pattern: pattern, user: %{id: user.id, name: user.name, username: username}}

          {:error, _} ->
            Error.fail("This code-owner rule already exists", 409)
        end
    end
  end

  def remove_codeowner(repository, actor, id) do
    unless Repositories.permitted?(repository, actor, :manage),
      do: Error.fail("Owner access required", 403)

    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail("Code-owner rule not found", 404)

    rule =
      Repo.get_by(Codeowner, id: id, repository_id: repository.id) ||
        Error.fail("Code-owner rule not found", 404)

    Repo.delete!(rule)
    :ok
  end

  def settings(attrs, current) do
    %{
      required_statuses:
        string_list(attrs, "required_statuses", current.required_statuses, &status_context!/1),
      protected_paths:
        string_list(attrs, "protected_paths", current.protected_paths, &pattern!/1),
      push_allowlist: uuid_list(attrs, "push_allowlist", current.push_allowlist),
      require_signed_commits:
        boolean(attrs, "require_signed_commits", current.require_signed_commits)
    }
  end

  def enforce_push!(repository, user) do
    allowed = repository.push_allowlist || []

    if allowed != [] and user.id not in allowed and
         Repositories.role(repository, user) != "owner",
       do: Error.fail("Repository policy does not allow this user to push", 403)

    :ok
  end

  def enforce_review!(repository, review, change) do
    paths = changed_paths(repository, review, change)
    decisions = current_approvals(review)
    enforce_statuses!(repository, change.id)
    enforce_protected_paths!(repository, paths, decisions)
    enforce_codeowners!(repository, paths, decisions)

    if repository.require_signed_commits and not Flurry.Engine.Keys.signed?(change.id),
      do: Error.fail("Repository policy requires a valid change signature", 409)

    :ok
  end

  def path_matches?(pattern, path) do
    source =
      pattern
      |> String.graphemes()
      |> glob([], false)
      |> IO.iodata_to_binary()

    Regex.match?(Regex.compile!("\\A" <> source <> "\\z", "u"), path)
  end

  defp changed_paths(repository, %{series: true} = review, change) do
    Changesets.delta(
      Changesets.root(repository, review.base_id),
      Changesets.root(repository, change.id)
    )
    |> Map.keys()
  end

  defp changed_paths(_, _, change), do: Map.keys(change.changes)

  defp current_approvals(review) do
    Repo.all(
      from(d in ReviewDecision,
        where:
          d.review_id == ^review.id and d.revision_id == ^review.changeset_id and
            d.decision == "approve",
        select: d.user_id
      )
    )
    |> MapSet.new()
  end

  defp enforce_statuses!(repository, revision) do
    statuses = Statuses.list(repository, revision) |> Map.new(&{&1.context, &1.state})

    failing =
      (repository.required_statuses || [])
      |> Enum.reject(&(statuses[&1] == "success"))

    if failing != [],
      do: Error.fail("Required status checks have not succeeded", 409, %{contexts: failing})
  end

  defp enforce_protected_paths!(repository, paths, decisions) do
    protected = repository.protected_paths || []

    if Enum.any?(paths, fn path -> Enum.any?(protected, &path_matches?(&1, path)) end) do
      owner_approved =
        Enum.any?(decisions, fn user_id ->
          case Repo.get(User, user_id) do
            nil -> false
            user -> Repositories.role(repository, user) == "owner"
          end
        end)

      unless owner_approved,
        do: Error.fail("Protected paths require an owner approval", 409)
    end
  end

  defp enforce_codeowners!(repository, paths, decisions) do
    missing =
      Repo.all(from(c in Codeowner, where: c.repository_id == ^repository.id))
      |> Enum.filter(fn rule -> Enum.any?(paths, &path_matches?(rule.pattern, &1)) end)
      |> Enum.reject(&MapSet.member?(decisions, &1.user_id))
      |> Enum.map(& &1.pattern)
      |> Enum.uniq()

    if missing != [],
      do: Error.fail("Code-owner approval is required", 409, %{patterns: missing})
  end

  defp status_context!(value) do
    value = Auth.text!(value, "Status context", 100)

    if Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9 ._\/-]*\z/, value),
      do: value,
      else: Error.fail("Status context contains unsupported characters")
  end

  defp pattern!(value) do
    value = Auth.text!(value, "Path pattern", 200)

    unless String.valid?(value) and not String.starts_with?(value, "/") and
             not String.contains?(value, ["\\", <<0>>, ".."]),
           do: Error.fail("Path patterns must be portable repository globs")

    value
  end

  defp string_list(attrs, key, current, validate) do
    case Map.fetch(attrs, key) do
      :error ->
        current || []

      {:ok, values} when is_list(values) and length(values) <= 50 ->
        values |> Enum.map(validate) |> Enum.uniq()

      _ ->
        Error.fail("#{key} must contain at most 50 values")
    end
  end

  defp uuid_list(attrs, key, current) do
    case Map.fetch(attrs, key) do
      :error ->
        current || []

      {:ok, values} when is_list(values) and length(values) <= 100 ->
        Enum.map(values, fn value ->
          case Ecto.UUID.cast(value) do
            {:ok, uuid} -> uuid
            _ -> Error.fail("#{key} contains an invalid user identifier")
          end
        end)
        |> Enum.uniq()

      _ ->
        Error.fail("#{key} must contain at most 100 users")
    end
  end

  defp boolean(attrs, key, current) do
    case Map.fetch(attrs, key) do
      :error -> current
      {:ok, value} when is_boolean(value) -> value
      _ -> Error.fail("#{key} must be true or false")
    end
  end

  defp glob([], acc, _star), do: Enum.reverse(acc)
  defp glob(["*", "*" | rest], acc, _star), do: glob(rest, [".*" | acc], true)
  defp glob(["*" | rest], acc, _star), do: glob(rest, ["[^/]*" | acc], true)
  defp glob(["?" | rest], acc, _star), do: glob(rest, ["[^/]" | acc], false)

  defp glob([char | rest], acc, _star),
    do: glob(rest, [Regex.escape(char) | acc], false)
end
