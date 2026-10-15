defmodule MealPlannerApi.PlanningAgent.Supervisor do
  @moduledoc """
  Supervision tree of the planning agent: the global concurrency limiter,
  the Household registry, the dynamic supervisor of Planning Session
  processes and the task supervisor running agent turns.
  """

  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      MealPlannerApi.PlanningAgent.ConcurrencyLimiter,
      {Registry, keys: :unique, name: MealPlannerApi.PlanningAgent.Registry},
      {Task.Supervisor, name: MealPlannerApi.PlanningAgent.TaskSupervisor},
      {DynamicSupervisor,
       strategy: :one_for_one, name: MealPlannerApi.PlanningAgent.SessionSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
