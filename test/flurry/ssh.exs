defmodule Flurry.SshTest do
  use ExUnit.Case, async: false

  alias Flurry.{Auth, Repo}
  alias Flurry.Engine.{Changesets, Keys, Refs, Repositories, Reviews}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    directory = Path.join(System.tmp_dir!(), "flurry-ssh-test-" <> Ecto.UUID.generate())
    host_keys = Path.join(directory, "host")
    client_key = Path.join(directory, "client")
    File.mkdir_p!(host_keys)

    {_, 0} =
      System.cmd("ssh-keygen", [
        "-q",
        "-t",
        "ed25519",
        "-N",
        "",
        "-f",
        Path.join(host_keys, "ssh_host_ed25519_key")
      ])

    {_, 0} =
      System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", client_key])

    on_exit(fn -> File.rm_rf(directory) end)
    {:ok, directory: directory, host_keys: host_keys, client_key: client_key}
  end

  test "ordinary Git clones through authenticated SSH", context do
    user = user()
    repository = Repositories.create(user, %{"name" => "sshclone"})

    submitted =
      Changesets.submit(repository, user, %{
        "base" => nil,
        "message" => "Initial files",
        "files" => [%{"path" => "readme.md", "content" => "through ssh\n"}]
      })

    Reviews.approve(repository, submitted.review_id, user)
    Reviews.land(repository, submitted.review_id, user)

    public_key = File.read!(context.client_key <> ".pub")
    Keys.add_ssh(user, %{"title" => "test", "public_key" => public_key})

    {:ok, daemon} =
      :ssh.daemon(0,
        system_dir: String.to_charlist(context.host_keys),
        key_cb: {Flurry.Git.SshKey, []},
        auth_methods: ~c"publickey",
        shell: :disabled,
        ssh_cli: {Flurry.Git.SshSession, []},
        subsystems: [],
        tcpip_tunnel_in: false,
        tcpip_tunnel_out: false,
        max_channels: 1,
        idle_time: 120_000
      )

    on_exit(fn -> :ssh.stop_daemon(daemon) end)
    {:port, port} = :ssh.daemon_info(daemon, :port)
    clone = Path.join(context.directory, "clone")

    command =
      Enum.join(
        [
          "ssh",
          "-i",
          context.client_key,
          "-o",
          "IdentitiesOnly=yes",
          "-o",
          "BatchMode=yes",
          "-o",
          "StrictHostKeyChecking=no",
          "-o",
          "UserKnownHostsFile=/dev/null"
        ],
        " "
      )

    url =
      "ssh://#{user.username}@127.0.0.1:#{port}/repositories/#{repository.id}.git"

    {output, status} =
      System.cmd("git", ["-c", "core.sshCommand=" <> command, "clone", url, clone],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert File.read!(Path.join(clone, "readme.md")) == "through ssh\n"

    {_, 0} = System.cmd("git", ["checkout", "-b", "topic"], cd: clone, stderr_to_stdout: true)
    File.write!(Path.join(clone, "readme.md"), "pushed through ssh\n")
    {_, 0} = System.cmd("git", ["add", "readme.md"], cd: clone, stderr_to_stdout: true)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=SSH Test",
          "-c",
          "user.email=ssh@example.test",
          "commit",
          "-m",
          "SSH push"
        ],
        cd: clone,
        stderr_to_stdout: true
      )

    {push_output, push_status} =
      System.cmd(
        "git",
        ["-c", "core.sshCommand=" <> command, "push", "origin", "topic"],
        cd: clone,
        stderr_to_stdout: true
      )

    assert push_status == 0, push_output
    assert Enum.any?(Refs.list(repository).branches, &(&1.name == "topic"))

    {delete_output, delete_status} =
      System.cmd(
        "git",
        ["-c", "core.sshCommand=" <> command, "push", "origin", ":topic"],
        cd: clone,
        stderr_to_stdout: true
      )

    assert delete_status == 0, delete_output
    refute Enum.any?(Refs.list(repository).branches, &(&1.name == "topic"))
  end

  defp user do
    id = Ecto.UUID.generate() |> String.replace("-", "")

    Auth.signup(%{
      "name" => "SSH user",
      "username" => "u" <> id,
      "email" => id <> "@example.test",
      "password" => "correct horse battery staple"
    })
    |> elem(0)
  end
end
