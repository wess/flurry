defmodule Flurry.Instance do
  import Ecto.Query
  alias Flurry.{Auth, Error, Repo, Audit, Schema.Instance, Schema.User}

  @page 50

  def get, do: Repo.get!(Instance, 1)

  def public do
    instance = get()

    Map.take(instance, [:name, :registration, :require_signin, :allow_public, :default_visibility])
    |> Map.put(:ssh_port, Application.get_env(:flurry, :ssh_port))
  end

  def hosts, do: Application.get_env(:flurry, :git_hosts, get().git_hosts)
  def limits, do: Map.take(get(), [:file_bytes, :project_storage_bytes, :account_storage_bytes])
  def owner?(nil), do: false

  # the first account is the founding owner through the instance record. others
  # hold owner access through their own flag, which a disabled account cannot use
  def owner?(user),
    do: founder?(user) or (Map.get(user, :owner, false) and not Map.get(user, :disabled, false))

  def founder?(nil), do: false
  def founder?(user), do: get().owner_id == user.id

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

  def users(actor, params \\ %{}) do
    admin!(actor)
    scope = matching(params["q"])
    offset = offset!(params["offset"])
    founder = get().owner_id

    users =
      Repo.all(from(u in scope, order_by: [u.inserted_at, u.id], limit: @page, offset: ^offset))
      |> Enum.map(&summary(&1, founder))

    %{users: users, total: Repo.aggregate(scope, :count), limit: @page}
  end

  # everything an administrator may know about an account. credentials and
  # authenticator material are never selected into the result
  def user(actor, id) do
    admin!(actor)
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail("User not found", 404)
    target = Repo.get(User, id) || Error.fail("User not found", 404)
    usage = Flurry.Quota.usage(target)
    key = Ecto.UUID.dump!(target.id)
    now = DateTime.utc_now()

    live = fn table ->
      Repo.aggregate(from(r in table, where: r.user_id == ^key and r.expires_at > ^now), :count)
    end

    Map.take(target, [
      :email,
      :bio,
      :location,
      :website,
      :account_type,
      :private_profile,
      :hide_activity
    ])
    |> Map.merge(summary(target, get().owner_id))
    |> Map.merge(%{
      joined_at: target.inserted_at,
      email_verified: not is_nil(target.email_verified_at),
      two_factor: not is_nil(target.totp_secret),
      passkeys:
        Repo.aggregate(from(p in Flurry.Schema.Passkey, where: p.user_id == ^target.id), :count),
      sessions: live.("sessions"),
      tokens: live.("tokens"),
      repositories: usage.repositories,
      storage_bytes: usage.bytes
    })
  end

  def update_user(actor, id, attrs) do
    admin!(actor)

    unless is_boolean(attrs["admin"]) and is_boolean(attrs["disabled"]) and
             (is_nil(attrs["owner"]) or is_boolean(attrs["owner"])),
           do: Error.fail("Specify administrator and disabled flags")

    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail("User not found", 404)

    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(735202)")
        target = Repo.get!(User, id)
        founder = founder?(target)

        if founder and (not attrs["admin"] or attrs["disabled"] or attrs["owner"] == false),
          do: Error.fail("The founding owner cannot be demoted or disabled")

        # the founder owns the instance through its record, so the flag stays as it is
        owner = if founder or is_nil(attrs["owner"]), do: target.owner, else: attrs["owner"]

        if owner != target.owner do
          owner!(actor)

          if target.id == actor.id,
            do: Error.fail("Another owner must change your owner access")

          if owner and target.account_type != "human",
            do: Error.fail("Agent accounts cannot own the instance")
        end

        if owner and attrs["disabled"],
          do: Error.fail("Remove owner access before disabling this account")

        if target.id == actor.id and attrs["disabled"],
          do: Error.fail("You cannot disable your own account")

        # owner access always includes administration
        admin = attrs["admin"] or owner

        remaining =
          Repo.aggregate(
            from(u in User, where: u.admin and not u.disabled and u.id != ^id),
            :count
          )

        if remaining == 0 and (not admin or attrs["disabled"]),
          do: Error.fail("Keep at least one active administrator")

        result =
          target
          |> Ecto.Changeset.change(admin: admin, disabled: attrs["disabled"], owner: owner)
          |> Repo.update!()

        if result.disabled, do: Flurry.Security.Sessions.revoke_all(result)
        flags = summary(result, get().owner_id)

        Audit.record(actor, "user.update", nil, %{
          username: target.username,
          admin: flags.admin,
          owner: flags.owner,
          disabled: flags.disabled
        })

        flags
      end)

    result
  end

  defp summary(target, founder) do
    Map.take(target, [:id, :name, :username, :admin, :disabled])
    |> Map.merge(%{
      founder: target.id == founder,
      owner: target.id == founder or (target.owner and not target.disabled)
    })
  end

  defp matching(nil), do: User

  defp matching(term) when is_binary(term) do
    case String.trim(term) |> String.slice(0, 100) do
      "" ->
        User

      text ->
        like = "%" <> String.replace(text, ["\\", "%", "_"], &("\\" <> &1)) <> "%"

        from(u in User,
          where: ilike(u.username, ^like) or ilike(u.name, ^like) or ilike(u.email, ^like)
        )
    end
  end

  defp matching(_), do: Error.fail("Search text must be a string")

  defp offset!(nil), do: 0

  defp offset!(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset >= 0 -> offset
      _ -> Error.fail("Offset must be a non-negative integer")
    end
  end

  defp offset!(_), do: Error.fail("Offset must be a non-negative integer")
end
