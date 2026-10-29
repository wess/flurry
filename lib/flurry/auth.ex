defmodule Flurry.Auth do
  import Ecto.Query
  alias Flurry.{Error, Repo, Audit, Schema.User, Store.Objects}
  alias Flurry.Security.{Sessions, Factor}
  @iterations 210_000

  def ready?, do: Repo.exists?(User)

  def setup(attrs) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(735201)")
        if ready?(), do: Error.fail("An owner already exists", 409)
        user = create(attrs, true)
        {user, Sessions.issue(user)}
      end)

    {user, _token} = result
    Flurry.Security.Identity.send_verification(user)
    result
  end

  def signup(attrs) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(735201)")
        first = not ready?()

        unless first or Flurry.Instance.get().registration,
          do: Error.fail("Registration is closed; contact the instance administrator", 403)

        user = create(attrs, first)
        {user, Sessions.issue(user)}
      end)

    {user, _token} = result
    Flurry.Security.Identity.send_verification(user)
    result
  end

  defp create(attrs, admin) do
    name = text!(attrs["name"], "Name", 80)
    username = text!(attrs["username"], "Username", 40) |> String.downcase()

    unless Regex.match?(~r/\A[a-z0-9][a-z0-9.]*\z/, username),
      do: Error.fail("Usernames use lowercase letters, numbers, and dots")

    changeset =
      Ecto.Changeset.change(%User{},
        id: Ecto.UUID.generate(),
        name: name,
        username: username,
        email: email!(attrs["email"]),
        password: encode(password!(attrs["password"])),
        admin: admin
      )
      |> Ecto.Changeset.unique_constraint(:email)
      |> Ecto.Changeset.unique_constraint(:username)

    user =
      case Repo.insert(changeset) do
        {:ok, user} -> user
        {:error, _} -> Error.fail("Email or username is already registered", 409)
      end

    if admin, do: Flurry.Instance.claim(user)

    Audit.record(user, "account.create")
    user
  end

  def login(attrs) do
    identifier = attrs["login"] || attrs["email"]
    identifier = if is_binary(identifier), do: String.downcase(String.trim(identifier)), else: ""

    {:ok, result} =
      Repo.transaction(fn ->
        user =
          Repo.one(
            from(u in User,
              where: u.email == ^identifier or u.username == ^identifier,
              lock: "FOR UPDATE"
            )
          )

        encoded =
          if user,
            do: user.password,
            else: "#{@iterations}:00000000000000000000000000000000:#{String.duplicate("0", 64)}"

        unless verify(attrs["password"] || "", encoded) && user && not user.disabled &&
                 user.account_type == "human",
               do: Error.fail("Username, email, or password is incorrect", 401)

        user = Factor.check!(user, attrs["code"])
        token = Sessions.issue(user)
        Audit.record(user, "account.login")
        {user, token}
      end)

    result
  end

  def resolve(token) when is_binary(token) do
    if byte_size(token) > 256, do: Error.fail("Invalid session", 401)

    Repo.one(
      from(u in User,
        join: s in "sessions",
        on: s.user_id == u.id,
        where:
          s.id == ^Objects.digest(token) and s.expires_at > ^DateTime.utc_now() and not u.disabled,
        select: u
      )
    )
  end

  def resolve(_), do: nil

  def revoke(token) when is_binary(token),
    do: Repo.delete_all(from(s in "sessions", where: s.id == ^Objects.digest(token)))

  def revoke(_), do: :ok

  def public(user),
    do: %{
      id: user.id,
      name: user.name,
      username: user.username,
      bio: user.bio,
      location: user.location,
      website: user.website,
      joined_at: user.inserted_at,
      account_type: user.account_type
    }

  def me(user),
    do:
      Map.merge(public(user), %{
        email: user.email,
        email_verified: not is_nil(user.email_verified_at),
        admin: user.admin,
        private_profile: user.private_profile,
        hide_activity: user.hide_activity,
        preferences: user.preferences,
        two_factor: not is_nil(user.totp_secret),
        owner: Flurry.Instance.owner?(user)
      })

  def text!(value, label, limit) do
    unless is_binary(value) and String.valid?(value) and String.trim(value) != "" and
             byte_size(value) <= limit,
           do: Error.fail("#{label} is required and must be at most #{limit} bytes")

    String.trim(value)
  end

  def email!(value) do
    email = text!(value, "Email", 200) |> String.downcase()

    unless Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, email),
      do: Error.fail("Enter a valid email")

    email
  end

  def password!(value) do
    unless is_binary(value) and byte_size(value) in 12..1024,
      do: Error.fail("Use a password between 12 and 1024 bytes")

    value
  end

  def encode(password) do
    salt = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    hash =
      :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, 32) |> Base.encode16(case: :lower)

    "#{@iterations}:#{salt}:#{hash}"
  end

  def verify(password, encoded) when is_binary(password) and byte_size(password) <= 1024 do
    [iterations, salt, expected] = String.split(encoded, ":")

    actual =
      :crypto.pbkdf2_hmac(:sha256, password, salt, String.to_integer(iterations), 32)
      |> Base.encode16(case: :lower)

    Plug.Crypto.secure_compare(actual, expected)
  end

  def verify(_, _), do: false
end
