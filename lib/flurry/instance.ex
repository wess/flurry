defmodule Flurry.Instance do
  import Ecto.Query
  alias Flurry.{Auth, Error, Repo, Audit, Schema.Instance, Schema.User}

  def get, do: Repo.get!(Instance, 1)

  def public do
    instance = get()

    Map.take(instance, [:name, :registration, :require_signin, :allow_public, :default_visibility])
    |> Map.put(:ssh_port, Application.get_env(:flurry, :ssh_port))
  end

  def hosts, do: Application.get_env(:flurry, :git_hosts, get().git_hosts)
  def limits, do: Map.take(get(), [:file_bytes, :project_storage_bytes, :account_storage_bytes])
  def owner?(nil), do: false
  def owner?(user), do: get().owner_id == user.id

  def owner!(user),
    do: unless(owner?(user), do: Error.fail("Instance owner access required", 403))

  def claim(user) do
    Repo.update_all(from(i in Instance, where: i.id == 1 and is_nil(i.owner_id)),
      set: [owner_id: user.id]
    )
  end

  def admin!(user),
    do:
      unless(user && (user.admin or owner?(user)) && not user.disabled,
        do: Error.fail("Administrator access required", 403)
      )

  def update(user, attrs) do
    admin!(user)
    name = Auth.text!(attrs["name"], "Instance name", 60)
    visibility = attrs["default_visibility"]
    unless visibility in ["public", "private"], do: Error.fail("Choose a default visibility")

    flags =
      Enum.map([:registration, :require_signin, :allow_public], fn key ->
        value = attrs[Atom.to_string(key)]
        unless is_boolean(value), do: Error.fail("#{key} must be true or false")
        {key, value}
      end)

    if visibility == "public" and not flags[:allow_public],
      do: Error.fail("Public repositories are disabled; choose private as the default")

    hosts = attrs["git_hosts"] || hosts()

    unless is_list(hosts) and length(hosts) in 0..30 and
             Enum.all?(
               hosts,
               &(is_binary(&1) and Regex.match?(~r/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/, &1) and
                   not String.contains?(&1, ".."))
             ),
           do: Error.fail("Enter valid Git hostnames")

    if Application.get_env(:flurry, :git_hosts) && hosts != hosts(),
      do: Error.fail("Git hosts are controlled by FLURRY_GIT_HOSTS")

    limits = storage_limits!(attrs)

    {:ok, instance} =
      Repo.transaction(fn ->
        next =
          get()
          |> Ecto.Changeset.change(
            [name: name, default_visibility: visibility, git_hosts: Enum.uniq(hosts)] ++
              limits ++ flags
          )
          |> Repo.update!()

        Audit.record(user, "instance.update")
        next
      end)

    instance
  end

  def details(user) do
    admin!(user)

    Map.merge(public(), %{
      git_hosts: hosts(),
      git_hosts_locked: not is_nil(Application.get_env(:flurry, :git_hosts)),
      limits: limits(),
      diagnostics: %{
        version: Application.spec(:flurry, :vsn) |> to_string(),
        git_available: not is_nil(System.find_executable("git")),
        secure_cookies: Application.get_env(:flurry, :secure_cookies, false),
        two_factor_available: Flurry.Security.Vault.available?(),
        mail_configured: Flurry.Mail.configured?(),
        oauth_configured: Flurry.Engine.SourceConnections.configured?(),
        ssh_hosting: Flurry.Git.SshDaemon.configured?(),
        ci_available: false,
        storage: Flurry.Store.Objects.description(),
        backup: Flurry.Backup.description(),
        backup_configuration: Flurry.Backup.status()
      }
    })
  end

  defp storage_limits!(attrs) do
    current = limits()
    file = attrs["file_bytes"] || current.file_bytes
    project = attrs["project_storage_bytes"] || current.project_storage_bytes
    account = attrs["account_storage_bytes"] || current.account_storage_bytes

    unless is_integer(file) and file in 1..1_073_741_824,
      do: Error.fail("Maximum file size must be between 1 byte and 1 GiB")

    unless is_integer(project) and project >= 0 and is_integer(account) and account >= 0,
      do: Error.fail("Storage limits must be non-negative integers")

    if project > 0 and file > project,
      do: Error.fail("Maximum file size cannot exceed the project storage limit")

    if account > 0 and project > account,
      do: Error.fail("Project storage cannot exceed the account storage limit")

    [file_bytes: file, project_storage_bytes: project, account_storage_bytes: account]
  end

  def users(user) do
    admin!(user)

    Repo.all(from(u in User, order_by: u.inserted_at, limit: 200))
    |> Enum.map(fn target ->
      Map.take(target, [:id, :name, :username, :admin, :disabled])
      |> Map.put(:owner, owner?(target))
    end)
  end

  def update_user(actor, id, attrs) do
    admin!(actor)

    unless is_boolean(attrs["admin"]) and is_boolean(attrs["disabled"]),
      do: Error.fail("Specify administrator and disabled flags")

    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail("User not found", 404)

    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(735202)")
        target = Repo.get!(User, id)

        if owner?(target) and (not attrs["admin"] or attrs["disabled"]),
          do: Error.fail("The instance owner cannot be demoted or disabled")

        if target.id == actor.id and attrs["disabled"],
          do: Error.fail("You cannot disable your own account")

        remaining =
          Repo.aggregate(
            from(u in User, where: u.admin and not u.disabled and u.id != ^id),
            :count
          )

        if remaining == 0 and (not attrs["admin"] or attrs["disabled"]),
          do: Error.fail("Keep at least one active administrator")

        result =
          target
          |> Ecto.Changeset.change(admin: attrs["admin"], disabled: attrs["disabled"])
          |> Repo.update!()

        if result.disabled, do: Flurry.Security.Sessions.revoke_all(result)

        Audit.record(actor, "user.update", nil, %{
          username: target.username,
          admin: result.admin,
          disabled: result.disabled
        })

        result
      end)

    Map.take(result, [:id, :name, :username, :admin, :disabled])
  end
end
