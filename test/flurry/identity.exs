defmodule Flurry.IdentityTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Flurry.{Auth, Mail, Repo}
  alias Flurry.Engine.Notifications
  alias Flurry.Schema.{MailDelivery, User}
  alias Flurry.Security.Identity

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    id = Ecto.UUID.generate() |> String.replace("-", "")

    {user, session} =
      Auth.signup(%{
        "name" => "Identity tester",
        "username" => "u" <> id,
        "email" => id <> "@example.test",
        "password" => "correct horse battery staple"
      })

    %{user: user, session: session}
  end

  test "email verification tokens are expiring, single-use and stored only as digests", %{
    user: user
  } do
    refute Repo.get!(User, user.id).email_verified_at
    token = mail_token(user, "verify")
    refute Repo.get(Flurry.Schema.EmailToken, token)
    assert Identity.verify(token).email_verified_at

    assert_raise Flurry.Error, ~r/invalid or expired/, fn -> Identity.verify(token) end
  end

  test "password recovery is non-enumerating, rotates sessions and invalidates the link", %{
    user: user,
    session: session
  } do
    assert :ok = Identity.request_reset("missing@example.test")
    assert :ok = Identity.request_reset(user.email)
    token = mail_token(user, "reset")
    Identity.reset_password(token, "a completely different password")
    assert Auth.resolve(session) == nil

    assert_raise Flurry.Error, fn ->
      Auth.login(%{"email" => user.email, "password" => "correct horse battery staple"})
    end

    assert {logged_in, _} =
             Auth.login(%{
               "email" => user.email,
               "password" => "a completely different password"
             })

    assert logged_in.id == user.id

    assert_raise Flurry.Error, ~r/invalid or expired/, fn ->
      Identity.reset_password(token, "another sufficiently long password")
    end
  end

  test "notification inbox separates recipients and read state", %{user: user} do
    other = another_user()
    Notifications.notify(user.id, "review.requested", "Review requested", actor: other)
    Notifications.notify(other.id, "issue.assigned", "Issue assigned", actor: user)

    inbox = Notifications.list(user)
    assert inbox.unread == 1
    assert [%{title: "Review requested"} = notification] = inbox.notifications
    assert Notifications.read(user, notification.id).read_at
    assert Notifications.list(user, true).notifications == []
    assert Notifications.list(other).unread == 1
  end

  test "queued mail uses authenticated idempotent API delivery", %{user: user} do
    previous_mail = Application.get_env(:flurry, :mail)
    previous_options = Application.get_env(:flurry, :mail_req_options)

    on_exit(fn ->
      restore_env(:mail, previous_mail)
      restore_env(:mail_req_options, previous_options)
    end)

    Application.put_env(:flurry, :mail, %{
      url: "https://mail.example.test/api",
      api_key: "test-key",
      from: "Flurry <noreply@flurry.codes>"
    })

    Application.put_env(:flurry, :mail_req_options, plug: {Req.Test, Mail})

    delivery =
      Repo.one!(
        from(m in MailDelivery,
          where: m.user_id == ^user.id and m.kind == "verify",
          order_by: [desc: m.inserted_at],
          limit: 1
        )
      )

    Req.Test.expect(Mail, 2, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert conn.method == "POST"
      assert conn.request_path == "/api/emails"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == [delivery.id]
      assert decoded["from"] == "Flurry <noreply@flurry.codes>"
      assert decoded["to"] == [user.email]

      if Process.get(:mail_attempt) do
        Req.Test.json(conn, %{id: Ecto.UUID.generate()})
      else
        Process.put(:mail_attempt, true)
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{message: "unavailable"})
      end
    end)

    failed = Mail.deliver(delivery)
    assert failed.status == "failed"
    assert failed.attempts == 1

    delivered = Mail.deliver(failed)
    assert delivered.status == "delivered"
    assert delivered.attempts == 2
    assert delivered.delivered_at
  end

  defp mail_token(user, kind) do
    body =
      Repo.one!(
        from(m in MailDelivery,
          where: m.user_id == ^user.id and m.kind == ^kind,
          order_by: [desc: m.inserted_at],
          limit: 1,
          select: m.body
        )
      )

    [_, encoded] = Regex.run(~r/token=([^\s]+)/, body)
    URI.decode_www_form(encoded)
  end

  defp another_user do
    id = Ecto.UUID.generate() |> String.replace("-", "")

    {user, _} =
      Auth.signup(%{
        "name" => "Other user",
        "username" => "u" <> id,
        "email" => id <> "@example.test",
        "password" => "correct horse battery staple"
      })

    user
  end

  defp restore_env(key, nil), do: Application.delete_env(:flurry, key)
  defp restore_env(key, value), do: Application.put_env(:flurry, key, value)
end
