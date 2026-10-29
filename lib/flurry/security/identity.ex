defmodule Flurry.Security.Identity do
  import Ecto.Query

  alias Flurry.{Auth, Error, Mail, Repo}
  alias Flurry.Schema.{EmailToken, User}
  alias Flurry.Security.Sessions
  alias Flurry.Store.Objects

  def send_verification(user) do
    user = Repo.get!(User, user.id)

    if is_nil(user.email_verified_at) do
      token = issue(user, "verify", 24 * 60 * 60)

      Mail.enqueue(
        user,
        "verify",
        "Verify your Flurry email",
        "Verify your email address:\n\n#{public_url()}/verify-email?token=#{URI.encode_www_form(token)}\n\nThis link expires in 24 hours."
      )
    end

    :ok
  end

  def verify(token) do
    {:ok, user} =
      Repo.transaction(fn ->
        record = token!(token, "verify")
        user = Repo.get!(User, record.user_id)

        user =
          user |> Ecto.Changeset.change(email_verified_at: DateTime.utc_now()) |> Repo.update!()

        consume(record)
        user
      end)

    user
  end

  def request_reset(email) do
    normalized = if is_binary(email), do: String.downcase(String.trim(email)), else: ""
    user = Repo.get_by(User, email: normalized)

    if user && not user.disabled do
      token = issue(user, "reset", 60 * 60)

      Mail.enqueue(
        user,
        "reset",
        "Reset your Flurry password",
        "Reset your password:\n\n#{public_url()}/reset-password?token=#{URI.encode_www_form(token)}\n\nThis link expires in one hour. If you did not request it, no action is needed."
      )
    end

    :ok
  end

  def reset_password(token, password) do
    encoded = password |> Auth.password!() |> Auth.encode()

    {:ok, user} =
      Repo.transaction(fn ->
        record = token!(token, "reset")
        user = Repo.get!(User, record.user_id)
        user = user |> Ecto.Changeset.change(password: encoded) |> Repo.update!()
        consume(record)
        Sessions.revoke_all(user)
        Flurry.Audit.record(user, "account.password.reset")
        user
      end)

    user
  end

  defp issue(user, purpose, seconds) do
    raw = "flr_email_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      Repo.delete_all(
        from(t in EmailToken,
          where: t.user_id == ^user.id and t.purpose == ^purpose and is_nil(t.consumed_at)
        )
      )

      Repo.insert!(%EmailToken{
        digest: Objects.digest(raw),
        user_id: user.id,
        purpose: purpose,
        expires_at: DateTime.add(now, seconds),
        inserted_at: now
      })
    end)

    raw
  end

  defp token!(token, purpose) do
    digest = if is_binary(token) and byte_size(token) <= 256, do: Objects.digest(token), else: ""

    record =
      Repo.one(
        from(t in EmailToken,
          where: t.digest == ^digest and t.purpose == ^purpose,
          lock: "FOR UPDATE"
        )
      )

    unless record && is_nil(record.consumed_at) &&
             DateTime.compare(record.expires_at, DateTime.utc_now()) == :gt,
           do: Error.fail("This link is invalid or expired", 400)

    record
  end

  defp consume(record),
    do: record |> Ecto.Changeset.change(consumed_at: DateTime.utc_now()) |> Repo.update!()

  defp public_url do
    Application.get_env(:flurry, :public_url) ||
      "http://localhost:#{Application.get_env(:flurry, :port, 4040)}"
  end
end
