defmodule Flurry.Integrations.Worker do
  use GenServer

  @interval 5_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(state) do
    send(self(), :deliver)
    {:ok, state}
  end

  @impl true
  def handle_info(:deliver, state) do
    Task.Supervisor.start_child(Flurry.Deliveries, fn -> Flurry.Engine.Webhooks.process() end)
    Task.Supervisor.start_child(Flurry.Deliveries, fn -> Flurry.Mail.deliver_pending() end)
    Process.send_after(self(), :deliver, @interval)
    {:noreply, state}
  end
end
