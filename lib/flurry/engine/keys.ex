defmodule Flurry.Engine.Keys do
  import Ecto.Query
  alias Flurry.{Auth, Error, Repo}
  alias Flurry.Engine.Repositories

  alias Flurry.Schema.{
    ChangesetSignature,
    DeployKey,
    SigningKey,
    SshKey
  }

  def add_signing(user, attrs) do
    title = Auth.text!(attrs["title"], "Key title", 100)

    public =
      case Base.decode64(attrs["public_key"] || "") do
        {:ok, key} when byte_size(key) == 32 -> key
        _ -> Error.fail("Signing keys must be base64-encoded Ed25519 public keys")
      end

    fingerprint = fingerprint(public)

    %SigningKey{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      title: title,
      public_key: public,
      fingerprint: fingerprint
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint([:user_id, :fingerprint])
    |> insert!("This signing key is already registered")
    |> signing_public()
  end

  def signing(user) do
    Repo.all(from(k in SigningKey, where: k.user_id == ^user.id, order_by: k.inserted_at))
    |> Enum.map(&signing_public/1)
  end

  def remove_signing(user, id) do
    key = owned(SigningKey, user, id, "Signing key")

    if Repo.exists?(from(s in ChangesetSignature, where: s.key_id == ^key.id)),
      do: Error.fail("Signing keys used by repository history cannot be removed", 409)

    Repo.delete!(key)
    :ok
  end

  def add_ssh(user, attrs) do
    title = Auth.text!(attrs["title"], "Key title", 100)
    {public, fingerprint} = ssh_public!(attrs["public_key"])

    %SshKey{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      title: title,
      public_key: public,
      fingerprint: fingerprint
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:fingerprint)
    |> insert!("This SSH key is already registered")
    |> ssh_public()
  end

  def ssh(user) do
    Repo.all(from(k in SshKey, where: k.user_id == ^user.id, order_by: k.inserted_at))
    |> Enum.map(&ssh_public/1)
  end

  def ssh_user(fingerprint) do
    case Repo.get_by(SshKey, fingerprint: fingerprint) do
      nil -> nil
      key -> Repo.get(Flurry.Schema.User, key.user_id)
    end
  end

  def remove_ssh(user, id) do
    owned(SshKey, user, id, "SSH key") |> Repo.delete!()
    :ok
  end

  def add_deploy(repository, actor, attrs) do
    unless Repositories.permitted?(repository, actor, :manage),
      do: Error.fail("Owner access required", 403)

    title = Auth.text!(attrs["title"], "Key title", 100)
    {public, fingerprint} = ssh_public!(attrs["public_key"])
    write = Map.get(attrs, "write", false)
    unless is_boolean(write), do: Error.fail("Deploy key write access must be true or false")

    %DeployKey{
      id: Ecto.UUID.generate(),
      repository_id: repository.id,
      creator_id: actor.id,
      title: title,
      public_key: public,
      fingerprint: fingerprint,
      write: write
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint([:repository_id, :fingerprint])
    |> insert!("This deploy key is already registered for the repository")
    |> deploy_public()
  end

  def deploy(repository) do
    Repo.all(
      from(k in DeployKey, where: k.repository_id == ^repository.id, order_by: k.inserted_at)
    )
    |> Enum.map(&deploy_public/1)
  end

  def deploy_access(fingerprint) do
    case Repo.get_by(DeployKey, fingerprint: fingerprint) do
      nil -> nil
      key -> %{repository_id: key.repository_id, access: if(key.write, do: :write, else: :read)}
    end
  end

  def ssh_authenticated?(username, fingerprint)
      when is_binary(username) and is_binary(fingerprint) do
    case deploy_principal(username) do
      {:ok, id} ->
        Repo.exists?(
          from(k in DeployKey,
            join: u in Flurry.Schema.User,
            on: u.id == k.creator_id,
            where: k.id == ^id and k.fingerprint == ^fingerprint and not u.disabled
          )
        )

      :account ->
        Repo.exists?(
          from(k in SshKey,
            join: u in Flurry.Schema.User,
            on: u.id == k.user_id,
            where: u.username == ^username and k.fingerprint == ^fingerprint and not u.disabled
          )
        )

      :error ->
        false
    end
  end

  def ssh_authenticated?(_, _), do: false

  def ssh_principal(username) when is_binary(username) do
    case deploy_principal(username) do
      {:ok, id} ->
        case Repo.get(DeployKey, id) do
          nil ->
            nil

          key ->
            user = Repo.get(Flurry.Schema.User, key.creator_id)

            if user && not user.disabled,
              do: %{
                user: user,
                repository_id: key.repository_id,
                access: if(key.write, do: :write, else: :read)
              }
        end

      :account ->
        case Repo.get_by(Flurry.Schema.User, username: username, disabled: false) do
          nil -> nil
          user -> %{user: user, repository_id: nil, access: :account}
        end

      :error ->
        nil
    end
  end

  def ssh_principal(_), do: nil

  def remove_deploy(repository, actor, id) do
    unless Repositories.permitted?(repository, actor, :manage),
      do: Error.fail("Owner access required", 403)

    key = scoped(DeployKey, repository.id, id, "Deploy key")
    Repo.delete!(key)
    :ok
  end

  def verify_signature(_user, _digest, nil, required) do
    if required, do: Error.fail("This repository requires signed changes", 409), else: nil
  end

  def verify_signature(user, digest, attrs, _required) when is_map(attrs) do
    id = attrs["key_id"]
    key = owned(SigningKey, user, id, "Signing key")

    signature =
      case Base.decode64(attrs["signature"] || "") do
        {:ok, value} when byte_size(value) == 64 -> value
        _ -> Error.fail("Signature must be a base64-encoded Ed25519 signature")
      end

    unless :crypto.verify(:eddsa, :none, digest, signature, [key.public_key, :ed25519]),
      do: Error.fail("Change signature is invalid", 409)

    %{key: key, signature: signature, digest: digest}
  end

  def verify_signature(_, _, _, _), do: Error.fail("Signature must include key_id and signature")

  def record_signature(_changeset_id, nil), do: :ok

  def record_signature(changeset_id, verified) do
    Repo.insert(
      %ChangesetSignature{
        changeset_id: changeset_id,
        key_id: verified.key.id,
        payload_digest: verified.digest,
        signature: verified.signature,
        inserted_at: DateTime.utc_now()
      },
      on_conflict: :nothing,
      conflict_target: :changeset_id
    )

    :ok
  end

  def signed?(changeset_id),
    do: Repo.exists?(from(s in ChangesetSignature, where: s.changeset_id == ^changeset_id))

  defp ssh_public!(value) when is_binary(value) do
    case String.split(String.trim(value), ~r/\s+/, parts: 3) do
      ["ssh-ed25519", encoded | _] ->
        with {:ok, blob} <- Base.decode64(encoded),
             <<11::32, "ssh-ed25519", 32::32, _key::binary-size(32)>> <- blob do
          {"ssh-ed25519 " <> Base.encode64(blob), "SHA256:" <> fingerprint(blob)}
        else
          _ -> Error.fail("SSH keys must contain one valid Ed25519 public key")
        end

      _ ->
        Error.fail("SSH keys must contain one valid Ed25519 public key")
    end
  end

  defp ssh_public!(_), do: Error.fail("SSH public key is required")

  defp fingerprint(data),
    do: :crypto.hash(:sha256, data) |> Base.encode64(padding: false)

  defp deploy_principal("deploy-" <> id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp deploy_principal(_), do: :account

  defp owned(schema, user, id, label) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail(label <> " not found", 404)
    Repo.get_by(schema, id: id, user_id: user.id) || Error.fail(label <> " not found", 404)
  end

  defp scoped(schema, repository_id, id, label) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail(label <> " not found", 404)

    Repo.get_by(schema, id: id, repository_id: repository_id) ||
      Error.fail(label <> " not found", 404)
  end

  defp insert!(changeset, message) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, _} -> Error.fail(message, 409)
    end
  end

  defp signing_public(key),
    do: %{
      id: key.id,
      title: key.title,
      algorithm: key.algorithm,
      public_key: Base.encode64(key.public_key),
      fingerprint: key.fingerprint,
      inserted_at: key.inserted_at
    }

  defp ssh_public(key),
    do: %{
      id: key.id,
      title: key.title,
      public_key: key.public_key,
      fingerprint: key.fingerprint,
      inserted_at: key.inserted_at
    }

  defp deploy_public(key),
    do: %{
      id: key.id,
      title: key.title,
      public_key: key.public_key,
      fingerprint: key.fingerprint,
      write: key.write,
      inserted_at: key.inserted_at
    }
end
