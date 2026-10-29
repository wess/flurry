defmodule Flurry.Security.Accounts do
  import Ecto.Query
  alias Flurry.{Auth, Repo, Error, Audit, Schema.User}
  alias Flurry.Security.{Sessions, Factor}

  def confirm!(user, attrs) do
    fresh = Repo.get!(User, user.id)

    unless Auth.verify(attrs["password"] || "", fresh.password),
      do: Error.fail("Current password is incorrect", 401)

    Factor.check!(fresh, attrs["code"])
  end

  def change(user, attrs) do
    {:ok, result} =
      Repo.transaction(fn ->
        current = Repo.one!(from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE"))
        confirm!(current, attrs)
        email = Auth.email!(attrs["email"] || current.email)
        password = attrs["new_password"]
        fields = [email: email]

        fields =
          if email != current.email,
            do: Keyword.put(fields, :email_verified_at, nil),
            else: fields

        fields =
          if password in [nil, ""],
            do: fields,
            else: Keyword.put(fields, :password, Auth.encode(Auth.password!(password)))

        changeset =
          current |> Ecto.Changeset.change(fields) |> Ecto.Changeset.unique_constraint(:email)

        current =
          case Repo.update(changeset) do
            {:ok, current} -> current
            {:error, _} -> Error.fail("This email is already registered", 409)
          end

        Audit.record(current, "account.credentials")
        Sessions.rotate(current)
      end)

    {updated, _token} = result
    if updated.email != user.email, do: Flurry.Security.Identity.send_verification(updated)
    result
  end

  def preferences(user, attrs) do
    theme = attrs["theme"] || "light"
    visibility = attrs["default_visibility"] || "private"
    wrap = attrs["wrap_code"]
    private = attrs["private_profile"]
    activity = attrs["hide_activity"]

    unless theme in ["light", "dark", "system"] and visibility in ["private", "public"] and
             is_boolean(wrap) and is_boolean(private) and is_boolean(activity),
           do: Error.fail("Invalid profile preferences")

    user
    |> Ecto.Changeset.change(
      preferences: %{"theme" => theme, "default_visibility" => visibility, "wrap_code" => wrap},
      private_profile: private,
      hide_activity: activity
    )
    |> Repo.update!()
  end
end
