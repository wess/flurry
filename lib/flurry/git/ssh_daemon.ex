defmodule Flurry.Git.SshDaemon do
  use GenServer

  require Logger

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    case configuration() do
      nil ->
        :ignore

      {port, directory} ->
        options = [
          system_dir: String.to_charlist(directory),
          key_cb: {Flurry.Git.SshKey, []},
          auth_methods: ~c"publickey",
          shell: :disabled,
          ssh_cli: {Flurry.Git.SshSession, []},
          subsystems: [],
          tcpip_tunnel_in: false,
          tcpip_tunnel_out: false,
          parallel_login: false,
          max_sessions: 64,
          max_channels: 1,
          max_initial_idle_time: 15_000,
          negotiation_timeout: 15_000,
          hello_timeout: 15_000,
          idle_time: 120_000,
          id_string: ~c"Flurry"
        ]

        case :ssh.daemon(port, options) do
          {:ok, reference} -> {:ok, %{reference: reference}}
          {:error, reason} -> {:stop, {:ssh_daemon, reason}}
        end
    end
  end

  @impl true
  def terminate(_reason, %{reference: reference}) do
    :ssh.stop_daemon(reference)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  def configured? do
    not is_nil(configuration())
  end

  defp configuration do
    with port when is_integer(port) <- Application.get_env(:flurry, :ssh_port),
         directory when is_binary(directory) <-
           Application.get_env(:flurry, :ssh_host_key_dir) do
      {port, directory}
    else
      _ -> nil
    end
  end
end
