defmodule MealPlannerApi.CartSweeper do
  @moduledoc "Releases abandoned carts without requiring a client request."
  use GenServer

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, 30_000)
    Process.send_after(self(), :tick, interval)
    {:ok, interval}
  end

  @impl true
  def handle_info(:tick, interval) do
    MealPlannerApi.Cart.expire_due()
    Process.send_after(self(), :tick, interval)
    {:noreply, interval}
  end
end
