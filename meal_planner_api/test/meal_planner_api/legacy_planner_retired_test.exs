defmodule MealPlannerApi.LegacyPlannerRetiredTest do
  @moduledoc """
  The legacy planner is switched off (issue #110, spec #93): Households plan
  only through the culinary agent. These guards keep the retired pieces from
  coming back: the legacy planning channel and its regex intent parsing, the
  in-memory non-cancellable generation server, and the optimizer server with
  its silent greedy fallback.
  """

  use ExUnit.Case, async: true

  @retired [
    MealPlannerApiWeb.PlanningChannel,
    MealPlannerApiWeb.Channels.IntentAtomizer,
    MealPlannerApi.Generation.PlanningSessionServer,
    MealPlannerApi.Generation.PlanningSessionSupervisor,
    MealPlannerApi.Generation.Server,
    MealPlannerApi.Generation.Supervisor,
    MealPlannerApi.Services.GenerationService
  ]

  for module <- @retired do
    test "#{inspect(module)} is retired" do
      refute Code.ensure_loaded?(unquote(module))
    end
  end

  test "the application supervises no legacy planner process" do
    children =
      MealPlannerApi.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

    for module <- @retired, do: refute(module in children)
    assert MealPlannerApi.PlanningAgent.Supervisor in children
  end
end
