defmodule Flurry.Security.Passkeys do
  import Ecto.Query
  alias Flurry.{Audit, Auth, Error, Instance, Repo}
  alias Flurry.Schema.{Passkey, User}
  alias Flurry.Security.{Accounts, PasskeyChallenges, Sessions}

  @transports ["ble", "hybrid", "internal", "nfc", "smart-card", "usb"]

  def relying_party(conn) do
    origin = Application.get_env(:flurry, :public_url) || request_origin(conn)
    uri = URI.parse(origin)

    unless uri.scheme in ["http", "https"] and is_binary(uri.host),
      do: Error.fail("Passkeys are unavailable for this origin", 503)

    %{origin: origin, id: uri.host, name: Instance.get().name || "Flurry"}
  end

  def list(user) do
    Repo.all(
      from(p in Passkey,
        where: p.user_id == ^user.id,
        order_by: [asc: p.inserted_at],
        select: p
      )
    )
    |> Enum.map(&public/1)
  end

  def registration_options(user, attrs, rp) do
    Accounts.confirm!(user, attrs)
    {stored, challenge} = PasskeyChallenges.create(:registration, user.id, rp)

    exclude =
      Repo.all(from(p in Passkey, where: p.user_id == ^user.id, select: p.credential_id))
      |> Enum.map(&%{"type" => "public-key", "id" => encode(&1)})

    %{
      challenge_id: stored.id,
      publicKey: %{
        "challenge" => encode(challenge.bytes),
        "rp" => %{"id" => rp.id, "name" => rp.name},
        "user" => %{
          "id" => encode(Ecto.UUID.dump!(user.id)),
          "name" => user.username,
          "displayName" => user.name
        },
        "pubKeyCredParams" => [
          %{"type" => "public-key", "alg" => -7},
          %{"type" => "public-key", "alg" => -257}
        ],
        "timeout" => PasskeyChallenges.timeout_ms(),
        "attestation" => "none",
        "excludeCredentials" => exclude,
        "authenticatorSelection" => %{
          "residentKey" => "required",
          "requireResidentKey" => true,
          "userVerification" => "required"
        }
      }
    }
  end

  def register(user, attrs) do
    challenge = PasskeyChallenges.consume(attrs["challenge_id"], :registration, user.id)
    raw_id = decode!(attrs["raw_id"], "Passkey credential", 1_024)
    client_data = decode!(attrs["client_data_json"], "Passkey client data", 16_384)
    attestation = decode!(attrs["attestation_object"], "Passkey attestation", 262_144)
    name = Auth.text!(attrs["name"], "Passkey name", 80)

    {:ok, result} =
      Repo.transaction(fn ->
        current = Repo.one!(from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE"))

        if current.disabled or current.account_type != "human",
          do: Error.fail("Passkey registration could not be verified", 401)

        auth_data = verify_registration(attestation, client_data, challenge)
        credential = auth_data.attested_credential_data

        unless credential && credential.credential_id == raw_id,
          do: Error.fail("Passkey registration could not be verified", 401)

        passkey =
          %Passkey{}
          |> Ecto.Changeset.change(
            id: Ecto.UUID.generate(),
            user_id: current.id,
            credential_id: raw_id,
            public_key: :erlang.term_to_binary(credential.credential_public_key),
            name: name,
            sign_count: auth_data.sign_count,
            aaguid: Wax.AuthenticatorData.get_aaguid(auth_data),
            transports: transports(attrs["transports"]),
            backed_up: auth_data.flag_credential_backed_up
          )
          |> Ecto.Changeset.unique_constraint(:credential_id)
          |> Repo.insert()
          |> case do
            {:ok, value} -> value
            {:error, _} -> Error.fail("This passkey is already registered", 409)
          end

        Audit.record(current, "passkey.create", nil, %{passkey: passkey.id})
        {current, token} = Sessions.rotate(current)
        {public(passkey), current, token}
      end)

    result
  end

  def authentication_options(rp) do
    {stored, challenge} = PasskeyChallenges.create(:authentication, nil, rp)

    %{
      challenge_id: stored.id,
      publicKey: %{
        "challenge" => encode(challenge.bytes),
        "rpId" => rp.id,
        "timeout" => PasskeyChallenges.timeout_ms(),
        "userVerification" => "required"
      }
    }
  end

  def authenticate(attrs) do
    challenge = PasskeyChallenges.consume(attrs["challenge_id"], :authentication, nil)
    raw_id = decode!(attrs["raw_id"], "Passkey credential", 1_024)
    user_handle = decode!(attrs["user_handle"], "Passkey user handle", 64)
    client_data = decode!(attrs["client_data_json"], "Passkey client data", 16_384)
    authenticator_data = decode!(attrs["authenticator_data"], "Authenticator data", 16_384)
    signature = decode!(attrs["signature"], "Passkey signature", 16_384)

    {:ok, result} =
      Repo.transaction(fn ->
        passkey =
          Repo.one(
            from(p in Passkey,
              where: p.credential_id == ^raw_id,
              lock: "FOR UPDATE"
            )
          ) || Error.fail("Passkey sign-in could not be verified", 401)

        user = Repo.get!(User, passkey.user_id)

        unless user_handle == Ecto.UUID.dump!(user.id) and not user.disabled and
                 user.account_type == "human",
               do: Error.fail("Passkey sign-in could not be verified", 401)

        key = :erlang.binary_to_term(passkey.public_key, [:safe])

        auth_data =
          verify_authentication(
            raw_id,
            authenticator_data,
            signature,
            client_data,
            challenge,
            key
          )

        if passkey.sign_count > 0 and auth_data.sign_count <= passkey.sign_count,
          do: Error.fail("Passkey sign-in could not be verified", 401)

        passkey
        |> Ecto.Changeset.change(
          sign_count: auth_data.sign_count,
          backed_up: auth_data.flag_credential_backed_up,
          last_used_at: DateTime.utc_now()
        )
        |> Repo.update!()

        token = Sessions.issue(user, "Passkey sign-in")
        Audit.record(user, "passkey.login", nil, %{passkey: passkey.id})
        {user, token}
      end)

    result
  end

  def rename(user, id, attrs) do
    passkey = owned!(user, id)

    passkey
    |> Ecto.Changeset.change(name: Auth.text!(attrs["name"], "Passkey name", 80))
    |> Repo.update!()
    |> tap(fn value -> Audit.record(user, "passkey.rename", nil, %{passkey: value.id}) end)
    |> public()
  end

  def revoke(user, id, attrs) do
    Accounts.confirm!(user, attrs)

    {:ok, result} =
      Repo.transaction(fn ->
        passkey = owned!(user, id)
        Repo.delete!(passkey)
        Audit.record(user, "passkey.revoke", nil, %{passkey: passkey.id})
        Sessions.rotate(user)
      end)

    result
  end

  defp verify_registration(attestation, client_data, challenge) do
    case Wax.register(attestation, client_data, challenge) do
      {:ok, {auth_data, _attestation}} -> auth_data
      {:error, _} -> Error.fail("Passkey registration could not be verified", 401)
    end
  rescue
    _ -> Error.fail("Passkey registration could not be verified", 401)
  end

  defp verify_authentication(raw_id, authenticator_data, signature, client_data, challenge, key) do
    case Wax.authenticate(
           raw_id,
           authenticator_data,
           signature,
           client_data,
           challenge,
           [{raw_id, key}]
         ) do
      {:ok, value} -> value
      {:error, _} -> Error.fail("Passkey sign-in could not be verified", 401)
    end
  rescue
    _ -> Error.fail("Passkey sign-in could not be verified", 401)
  end

  defp owned!(user, id) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail("Passkey not found", 404)

    Repo.get_by(Passkey, id: id, user_id: user.id) || Error.fail("Passkey not found", 404)
  end

  defp public(passkey),
    do: %{
      id: passkey.id,
      name: passkey.name,
      transports: passkey.transports,
      backed_up: passkey.backed_up,
      last_used_at: passkey.last_used_at,
      inserted_at: passkey.inserted_at
    }

  defp decode!(value, label, limit) when is_binary(value) and byte_size(value) <= limit * 2 do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} when byte_size(decoded) <= limit -> decoded
      _ -> Error.fail("#{label} is invalid", 400)
    end
  end

  defp decode!(_, label, _limit), do: Error.fail("#{label} is invalid", 400)
  defp encode(value), do: Base.url_encode64(value, padding: false)

  defp transports(values) when is_list(values),
    do: values |> Enum.filter(&(&1 in @transports)) |> Enum.uniq() |> Enum.take(8)

  defp transports(_), do: []

  defp request_origin(conn) do
    scheme = Atom.to_string(conn.scheme)
    default = (scheme == "https" and conn.port == 443) or (scheme == "http" and conn.port == 80)
    scheme <> "://" <> conn.host <> if(default, do: "", else: ":#{conn.port}")
  end
end
