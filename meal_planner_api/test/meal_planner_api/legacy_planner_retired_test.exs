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
    MealPlannerApi.Services.GenerationService,
    MealPlannerApi.Optimization.OptimizerServer,
    MealPlannerApi.Optimization.OptimizerFallback,
    MealPlannerApi.Optimization.OptimizerMock,
    MealPlannerApi.Optimization.PayloadAdapter,
    MealPlannerApi.Planning
  ]

  # REST endpoints that generated or saved plans outside the agent.
  @retired_routes [
    {"GET", "/api/planning/weekly"},
    {"POST", "/api/planning/confirm"},
    {"POST", "/api/planning/chat"},
    {"POST", "/api/planning/proposals/00000000-0000-0000-0000-000000000001/reject"}
  ]

  # Endpoints that read favorites stay.
  @kept_routes [
    {"GET", "/api/planning/favorites"},
    {"PUT", "/api/planning/slots/favorite"}
  ]

  for module <- @retired do
    test "#{inspect(module)} is retired" do
      refute Code.ensure_loaded?(unquote(module))
    end
  end

  for {verb, path} <- @retired_routes do
    test "#{verb} #{path} is no longer routed" do
      assert :error =
               Phoenix.Router.route_info(
                 MealPlannerApiWeb.Router,
                 unquote(verb),
                 unquote(path),
                 ""
               )
    end
  end

  for {verb, path} <- @kept_routes do
    test "#{verb} #{path} is still routed" do
      assert %{} =
               Phoenix.Router.route_info(
                 MealPlannerApiWeb.Router,
                 unquote(verb),
                 unquote(path),
                 ""
               )
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
