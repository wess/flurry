defmodule Flurry.PoliciesTest do
  use ExUnit.Case, async: false
  alias Flurry.{Auth, Repo}
  alias Flurry.Engine.{Changesets, Keys, Policies, Repositories, Reviews, Settings, Statuses}
  alias Flurry.Store.Objects

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "signed changes, required statuses, protected paths and code owners gate landing" do
    owner = user("Owner")
    reviewer = user("Reviewer")
    repository = Repositories.create(owner, %{"name" => "policy"})
    maintain(repository, reviewer)

    repository =
      Settings.update(repository, owner, %{
        "required_approvals" => 2,
        "required_statuses" => ["quality/tests"],
        "protected_paths" => ["policy/**"],
        "require_signed_commits" => true
      })

    Policies.add_codeowner(repository, owner, %{
      "pattern" => "policy/**",
      "username" => reviewer.username
    })

    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    key =
      Keys.add_signing(owner, %{
        "title" => "workstation",
        "public_key" => Base.encode64(public)
      })

    attrs = %{
      "base" => nil,
      "message" => "Add policy",
      "files" => [%{"path" => "policy/rules.txt", "content" => "required\n"}]
    }

    assert_raise Flurry.Error, ~r/requires signed/, fn ->
      Changesets.submit(repository, owner, attrs)
    end

    changes = %{"policy/rules.txt" => Objects.put(:blob, "required\n")}
    digest = Changesets.signature_digest(repository.id, nil, nil, "Add policy", changes)
    signature = :crypto.sign(:eddsa, :none, digest, [private, :ed25519])

    submitted =
      Changesets.submit(
        repository,
        owner,
        Map.put(attrs, "signature", %{
          "key_id" => key.id,
          "signature" => Base.encode64(signature)
        })
      )

    Reviews.approve(repository, submitted.review_id, owner)

    assert_raise Flurry.Error, ~r/current approvals/, fn ->
      Reviews.land(repository, submitted.review_id, owner)
    end

    Reviews.approve(repository, submitted.review_id, reviewer)

    error =
      assert_raise Flurry.Error, ~r/Required status checks/, fn ->
        Reviews.land(repository, submitted.review_id, owner)
      end

    assert error.details.contexts == ["quality/tests"]

    Statuses.put(repository, owner, submitted.changeset.id, %{
      "context" => "quality/tests",
      "state" => "success"
    })

    assert Reviews.land(repository, submitted.review_id, owner).head == submitted.changeset.id
  end

  test "push allowlists and SSH key records are enforced" do
    owner = user("Owner")
    writer = user("Writer")
    repository = Repositories.create(owner, %{"name" => "keys"})
    maintain(repository, writer)

    repository =
      Settings.update(repository, owner, %{"push_allowlist" => [owner.id]})

    assert Policies.enforce_push!(repository, owner) == :ok
    assert_raise Flurry.Error, fn -> Policies.enforce_push!(repository, writer) end

    {public, _private} = :crypto.generate_key(:eddsa, :ed25519)
    blob = <<11::32, "ssh-ed25519", 32::32, public::binary>>
    text = "ssh-ed25519 " <> Base.encode64(blob) <> " local"
    key = Keys.add_ssh(owner, %{"title" => "laptop", "public_key" => text})
    assert key.public_key == "ssh-ed25519 " <> Base.encode64(blob)
    assert Keys.ssh_user(key.fingerprint).id == owner.id
    assert Keys.ssh_authenticated?(owner.username, key.fingerprint)
    assert Keys.ssh_principal(owner.username).user.id == owner.id

    [{decoded, _}] = :ssh_file.decode(text, :openssh_key)
    assert Flurry.Git.SshKey.is_auth_key(decoded, String.to_charlist(owner.username), [])

    deploy =
      Keys.add_deploy(repository, owner, %{
        "title" => "reader",
        "public_key" => text,
        "write" => false
      })

    assert Keys.deploy_access(deploy.fingerprint) == %{
             repository_id: repository.id,
             access: :read
           }

    principal = "deploy-" <> deploy.id
    assert Keys.ssh_authenticated?(principal, deploy.fingerprint)
    assert Keys.ssh_principal(principal).repository_id == repository.id
  end

  defp user(name) do
    id = Ecto.UUID.generate() |> String.replace("-", "")

    Auth.signup(%{
      "name" => name,
      "username" => "u" <> id,
      "email" => id <> "@example.test",
      "password" => "correct horse battery staple"
    })
    |> elem(0)
  end

  defp maintain(repository, user) do
    Repo.insert_all("members", [
      %{
        repository_id: Ecto.UUID.dump!(repository.id),
        user_id: Ecto.UUID.dump!(user.id),
        role: "maintain"
      }
    ])
  end
end
