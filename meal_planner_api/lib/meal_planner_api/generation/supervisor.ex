defmodule MealPlannerApi.Generation.Supervisor do
  @moduledoc """
  DynamicSupervisor para instancias de GenerationServer.

  Un servidor por `account_id`. Se registra en `MealPlannerApi.Generation.Generations`
  (Registry) para que `start_generation/4` pueda encontrar procesos existentes.
  """

  use Supervisor

  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: MealPlannerApi.Generation.Generations},
      {DynamicSupervisor, strategy: :one_for_one, max_seconds: 5}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
