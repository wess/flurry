defmodule Flurry.Application do
  use Application

  def start(_type, _args) do
    children =
      [
        Flurry.Repo,
        Flurry.Http.Limits,
        {Task.Supervisor, name: Flurry.Transfers, max_children: 2},
        {Task.Supervisor, name: Flurry.Deliveries, max_children: 4}
      ] ++ server()

    Supervisor.start_link(children, strategy: :one_for_one, name: Flurry.Supervisor)
  end

  defp server do
    if Application.get_env(:flurry, :server) do
      [
        Flurry.Git.Recovery,
        Flurry.Git.SshDaemon,
        Flurry.Integrations.Worker,
        {Bandit,
         plug: Flurry.Http.Router,
         port: Application.fetch_env!(:flurry, :port),
         ip: Application.fetch_env!(:flurry, :host)}
      ]
    else
      []
    end
  end
end
