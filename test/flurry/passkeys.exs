defmodule Flurry.PasskeysTest do
  use ExUnit.Case, async: false
  alias Flurry.{Auth, Repo}
  alias Flurry.Schema.Passkey
  alias Flurry.Security.Passkeys

  @password "correct horse battery staple"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    value = "p" <> (Ecto.UUID.generate() |> String.replace("-", ""))

    {user, _} =
      Auth.signup(%{
        "name" => "Passkey tester",
        "username" => value,
        "email" => value <> "@example.test",
        "password" => @password
      })

    %{user: user, rp: %{origin: "https://flurry.example", id: "flurry.example", name: "Flurry"}}
  end

  test "registration options require identity confirmation and request a discoverable credential",
       ctx do
    assert_raise Flurry.Error, ~r/password/, fn ->
      Passkeys.registration_options(ctx.user, %{"password" => "wrong"}, ctx.rp)
    end

    options = Passkeys.registration_options(ctx.user, %{"password" => @password}, ctx.rp)
    assert options.publicKey["rp"]["id"] == "flurry.example"
    assert options.publicKey["authenticatorSelection"]["residentKey"] == "required"
    assert options.publicKey["authenticatorSelection"]["userVerification"] == "required"
  end

  test "passkeys can be listed, renamed, and revoked with fresh confirmation", ctx do
    passkey =
      Repo.insert!(%Passkey{
        id: Ecto.UUID.generate(),
        user_id: ctx.user.id,
        credential_id: :crypto.strong_rand_bytes(32),
        public_key: :erlang.term_to_binary(%{1 => 2, 3 => -7}),
        name: "Laptop"
      })

    assert [%{name: "Laptop"}] = Passkeys.list(ctx.user)

    assert %{name: "Security key"} =
             Passkeys.rename(ctx.user, passkey.id, %{"name" => "Security key"})

    assert_raise Flurry.Error, ~r/password/, fn ->
      Passkeys.revoke(ctx.user, passkey.id, %{"password" => "wrong"})
    end

    {_user, token} = Passkeys.revoke(ctx.user, passkey.id, %{"password" => @password})
    assert is_binary(token)
    assert Passkeys.list(ctx.user) == []
  end

  test "authentication challenges are single use even when verification fails", ctx do
    options = Passkeys.authentication_options(ctx.rp)
    encoded = Base.url_encode64("unknown", padding: false)

    attrs = %{
      "challenge_id" => options.challenge_id,
      "raw_id" => encoded,
      "user_handle" => encoded,
      "client_data_json" => encoded,
      "authenticator_data" => encoded,
      "signature" => encoded
    }

    assert_raise Flurry.Error, ~r/could not be verified/, fn -> Passkeys.authenticate(attrs) end
    assert_raise Flurry.Error, ~r/expired/, fn -> Passkeys.authenticate(attrs) end
  end
end
