defmodule Flurry.Security.Factor do
  import Ecto.Query
  alias Flurry.{Repo, Error, Audit, Schema.User, Store.Objects}
  alias Flurry.Security.{Accounts, Vault, Sessions}

  def check!(%{totp_secret: nil} = user, _), do: user

  def check!(user, code) do
    if not is_binary(code) or byte_size(code) > 100,
      do: Error.fail("Enter an authenticator or recovery code", 401)

    {:ok, current} =
      Repo.transaction(fn ->
        current = Repo.one!(from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE"))
        digest = Objects.digest(String.trim(code))

        cond do
          digest in current.recovery_codes ->
            current
            |> Ecto.Changeset.change(recovery_codes: List.delete(current.recovery_codes, digest))
            |> Repo.update!()

          NimbleTOTP.valid?(Vault.decrypt(current.totp_secret), code, since: current.totp_last) ->
            current |> Ecto.Changeset.change(totp_last: System.os_time(:second)) |> Repo.update!()

          true ->
            Error.fail("Authenticator code is invalid or already used", 401)
        end
      end)

    current
  end

  def prepare(user, attrs) do
    Accounts.confirm!(user, attrs)
    if user.totp_secret, do: Error.fail("Two-factor authentication is already enabled")
    secret = NimbleTOTP.secret()

    user
    |> Ecto.Changeset.change(
      totp_pending: Vault.encrypt(secret),
      totp_expires: DateTime.add(DateTime.utc_now(), 600)
    )
    |> Repo.update!()

    %{
      secret: Base.encode32(secret, padding: false),
      uri: NimbleTOTP.otpauth_uri("Flurry:" <> user.username, secret, issuer: "Flurry")
    }
  end

  def enable(user, attrs) do
    {:ok, result} =
      Repo.transaction(fn ->
        current = Repo.one!(from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE"))

        unless Flurry.Auth.verify(attrs["password"] || "", current.password),
          do: Error.fail("Current password is incorrect", 401)

        unless current.totp_pending && current.totp_expires &&
                 DateTime.compare(current.totp_expires, DateTime.utc_now()) == :gt,
               do: Error.fail("Start two-factor setup again; the setup expired")

        code = attrs["code"] || ""

        unless is_binary(code) and NimbleTOTP.valid?(Vault.decrypt(current.totp_pending), code),
          do: Error.fail("Authenticator code is incorrect", 401)

        codes = recovery_codes()

        current =
          current
          |> Ecto.Changeset.change(
            totp_secret: current.totp_pending,
            totp_pending: nil,
            totp_expires: nil,
            totp_last: System.os_time(:second),
            recovery_codes: Enum.map(codes, &Objects.digest/1)
          )
          |> Repo.update!()

        Audit.record(current, "twofactor.enable")
        {current, token} = Sessions.rotate(current)
        {current, token, codes}
      end)

    result
  end

  def regenerate(user, attrs) do
    {:ok, result} =
      Repo.transaction(fn ->
        current = Accounts.confirm!(user, attrs)
        unless current.totp_secret, do: Error.fail("Two-factor authentication is not enabled")
        codes = recovery_codes()

        current =
          current
          |> Ecto.Changeset.change(recovery_codes: Enum.map(codes, &Objects.digest/1))
          |> Repo.update!()

        Audit.record(current, "twofactor.recoverycodes")
        {current, token} = Sessions.rotate(current)
        {current, token, codes}
      end)

    result
  end

  def disable(user, attrs) do
    {:ok, result} =
      Repo.transaction(fn ->
        Accounts.confirm!(user, attrs)

        current =
          Repo.get!(User, user.id)
          |> Ecto.Changeset.change(
            totp_secret: nil,
            totp_pending: nil,
            totp_expires: nil,
            totp_last: nil,
            recovery_codes: []
          )
          |> Repo.update!()

        Audit.record(current, "twofactor.disable")
        Sessions.rotate(current)
      end)

    result
  end

  defp recovery_codes,
    do: Enum.map(1..10, fn _ -> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower) end)
end
