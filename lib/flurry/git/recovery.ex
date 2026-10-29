defmodule Flurry.Git.Recovery do
  use GenServer
  import Ecto.Query
  alias Flurry.{Repo, Schema.Source}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)
  def init(state), do: {:ok, state, {:continue, :recover}}

  def handle_continue(:recover, state) do
    try do
      Repo.update_all(from(s in Source, where: s.status == "running"),
        set: [
          status: "failed",
          error: "The server restarted during this transfer. Retry to confirm or resume it.",
          updated_at: DateTime.utc_now()
        ]
      )
    rescue
      Postgrex.Error -> :ok
    end

    {:noreply, state}
  end
end
