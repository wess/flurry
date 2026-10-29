defmodule Flurry.Http.Limits do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(state), do: {:ok, state}

  def allow?(address),
    do: allow?({:sensitive, address}, Application.get_env(:flurry, :rate_limit, 20))

  def allow?(key, limit), do: GenServer.call(__MODULE__, {:allow, key, limit})

  def handle_call({:allow, key, limit}, _from, state) do
    now = System.monotonic_time(:second)
    state = Map.reject(state, fn {_, {start, _}} -> now - start >= 60 end)
    {start, count} = Map.get(state, key, {now, 0})
    {:reply, count < limit, Map.put(state, key, {start, count + 1})}
  end
end
