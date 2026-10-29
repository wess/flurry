defmodule Flurry.Git.SshSession do
  @behaviour :ssh_server_channel

  alias Flurry.{Error, Git.Import, Git.Mirror}
  alias Flurry.Engine.{Keys, Repositories}

  @transfer_limit 268_435_456
  @timeout 120_000

  @impl true
  def init([]), do: {:ok, %{cm: nil, channel: nil, port: nil, directory: nil, size: 0}}

  @impl true
  def handle_ssh_msg(
        {:ssh_cm, cm, {:exec, channel, want_reply, command}},
        %{port: nil} = state
      ) do
    case open(cm, command) do
      {:ok, transfer} ->
        :ssh_connection.reply_request(cm, want_reply, :success, channel)
        Process.send_after(self(), :transfer_timeout, @timeout)
        {:ok, Map.merge(state, transfer) |> Map.merge(%{cm: cm, channel: channel})}

      {:error, message} ->
        :ssh_connection.reply_request(cm, want_reply, :failure, channel)
        :ssh_connection.send(cm, channel, 1, message)
        :ssh_connection.exit_status(cm, channel, 255)
        :ssh_connection.send_eof(cm, channel)
        {:stop, channel, %{state | cm: cm, channel: channel}}
    end
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:data, _channel, 0, data}}, %{port: port} = state)
      when not is_nil(port) do
    Port.command(port, data)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, cm, {:shell, channel, want_reply}}, state) do
    :ssh_connection.reply_request(cm, want_reply, :failure, channel)
    :ssh_connection.exit_status(cm, channel, 255)
    :ssh_connection.send_eof(cm, channel)
    {:stop, channel, %{state | cm: cm, channel: channel}}
  end

  def handle_ssh_msg({:ssh_cm, cm, {:env, channel, want_reply, _key, _value}}, state) do
    :ssh_connection.reply_request(cm, want_reply, :failure, channel)
    {:ok, %{state | cm: cm, channel: channel}}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:eof, _channel}}, state), do: {:ok, state}
  def handle_ssh_msg({:ssh_cm, _cm, {:signal, _channel, _signal}}, state), do: {:ok, state}
  def handle_ssh_msg(_message, state), do: {:ok, state}

  @impl true
  def handle_msg({:ssh_channel_up, channel, cm}, state),
    do: {:ok, %{state | cm: cm, channel: channel}}

  def handle_msg({port, {:data, data}}, %{port: port} = state) do
    size = state.size + byte_size(data)

    if size > @transfer_limit do
      finish(state, 1)
    else
      :ssh_connection.send(state.cm, state.channel, data)
      {:ok, %{state | size: size}}
    end
  end

  def handle_msg({port, {:exit_status, 0}}, %{port: port} = state) do
    finish(state, apply_receive(state))
  end

  def handle_msg({port, {:exit_status, _}}, %{port: port} = state), do: finish(state, 1)
  def handle_msg(:transfer_timeout, state), do: finish(state, 1)
  def handle_msg(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    if state.port && Port.info(state.port), do: Port.close(state.port)
    if state.directory, do: File.rm_rf(state.directory)
    :ok
  end

  defp open(cm, command) do
    [{:user, username}] = :ssh.connection_info(cm, [:user])

    with {:ok, service, repository_id} <- parse(command),
         principal when not is_nil(principal) <- Keys.ssh_principal(to_string(username)),
         :ok <- authorized(principal, repository_id, service) do
      repository = Repositories.get(principal.user, repository_id, access(service))
      directory = Path.join(System.tmp_dir!(), "flurry-git-" <> random())
      File.mkdir_p!(directory)

      try do
        Mirror.materialize(repository, directory)
        {updates, extra} = receive_hook(service, directory)

        {:ok,
         %{
           port: git_port(service, directory, extra),
           directory: directory,
           repository: repository,
           user: principal.user,
           updates: updates,
           size: 0
         }}
      rescue
        error ->
          File.rm_rf(directory)
          reraise error, __STACKTRACE__
      end
    else
      _ -> {:error, "SSH Git request denied"}
    end
  rescue
    error in Error -> {:error, error.message}
    _ -> {:error, "SSH Git transfer failed"}
  end

  defp parse(command) do
    case Regex.run(
           ~r/\A(git-upload-pack|git-receive-pack) '(?:\/?repositories\/)?([0-9a-f-]{36})\.git'\z/,
           IO.iodata_to_binary(command)
         ) do
      [_, service, id] ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> {:ok, service, uuid}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp authorized(%{repository_id: nil}, _id, _service), do: :ok

  defp authorized(%{repository_id: id, access: permission}, id, "git-upload-pack")
       when permission in [:read, :write],
       do: :ok

  defp authorized(%{repository_id: id, access: :write}, id, "git-receive-pack"), do: :ok
  defp authorized(_, _, _), do: :error

  defp access("git-upload-pack"), do: :read
  defp access("git-receive-pack"), do: :write

  defp receive_hook("git-upload-pack", _directory), do: {nil, []}

  defp receive_hook("git-receive-pack", directory) do
    updates = Path.join(directory, "ssh-updates")
    hook = Path.join([directory, "hooks", "pre-receive"])
    File.mkdir_p!(Path.dirname(hook))

    File.write!(
      hook,
      "#!/bin/sh\ncat > \"$FLURRY_UPDATES\"\ncount=$(wc -l < \"$FLURRY_UPDATES\")\n[ \"$count\" -eq 1 ] || { echo 'push one ref at a time' >&2; exit 1; }\n",
      [:binary, :exclusive]
    )

    File.chmod!(hook, 0o700)
    {updates, [{"FLURRY_UPDATES", updates}]}
  end

  defp git_port(service, directory, extra) do
    git = System.find_executable("git") || Error.fail("Git is unavailable", 503)
    error_file = Path.join(directory, "git-error")
    command = String.replace_prefix(service, "git-", "")

    Port.open({:spawn_executable, ~c"/bin/sh"}, [
      :binary,
      :exit_status,
      :use_stdio,
      {:args,
       Enum.map(
         ["-c", "exec \"$@\" 2>\"$FLURRY_GIT_ERROR\"", "flurry-ssh", git, command, directory],
         &String.to_charlist/1
       )},
      {:cd, String.to_charlist(directory)},
      {:env, environment([{"FLURRY_GIT_ERROR", error_file} | extra])}
    ])
  end

  defp apply_receive(%{updates: nil}), do: 0

  defp apply_receive(state) do
    Import.apply(state.repository, state.user, state.directory, File.read!(state.updates))
    0
  rescue
    _ -> 1
  end

  defp finish(state, status) do
    :ssh_connection.exit_status(state.cm, state.channel, status)
    :ssh_connection.send_eof(state.cm, state.channel)
    {:stop, state.channel, state}
  end

  defp environment(extra) do
    inherited =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "GIT_"))
      |> Enum.map(&{String.to_charlist(&1), false})

    hooks =
      if Enum.any?(extra, fn {key, _} -> key == "FLURRY_UPDATES" end),
        do: "hooks",
        else: "/dev/null"

    configs = [{"core.hooksPath", hooks}, {"gc.auto", "0"}, {"fetch.fsckObjects", "true"}]

    values =
      [
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_TERMINAL_PROMPT", "0"},
        {"GIT_CONFIG_COUNT", to_string(length(configs))},
        {"LC_ALL", "C"}
      ] ++
        Enum.flat_map(Enum.with_index(configs), fn {{key, value}, index} ->
          [{"GIT_CONFIG_KEY_#{index}", key}, {"GIT_CONFIG_VALUE_#{index}", value}]
        end) ++ extra

    inherited ++
      Enum.map(values, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)
  end

  defp random, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
