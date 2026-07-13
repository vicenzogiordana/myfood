defmodule MealPlannerApi.Planning.PythonOptimizerClientTest do
  @moduledoc """
  TDD coverage for item 2 (planning-pipeline-plumbing): `config/config.exs`
  pointed `:planning_optimizer_client` at
  `MealPlannerApi.Planning.PythonOptimizerClient`, a module that didn't
  exist. Every real (non-test) call to the legacy
  `PlanningService.generate_weekly_plan/3` pipeline raised
  `UndefinedFunctionError` (`config/test.exs` overrides the config to
  `OptimizerMock`, so this was invisible to the whole test suite).
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.Planning.PythonOptimizerClient

  describe "configured optimizer client module" do
    test "the module configured in :planning_optimizer_client actually exists and implements OptimizerPort" do
      configured_module = Application.get_env(:meal_planner_api, :planning_optimizer_client)

      assert configured_module,
             "expected :planning_optimizer_client to be configured (checked at :meal_planner_api app env)"

      assert Code.ensure_loaded?(configured_module),
             "#{inspect(configured_module)} must exist and be loadable — this is what config.exs points at outside of test.exs's OptimizerMock override"

      assert function_exported?(configured_module, :select_weekly_menu, 1)
      assert function_exported?(configured_module, :health_check, 0)
    end
  end

  describe "to_optimizer_port_payload/1" do
    test "translates the legacy STRING-keyed PlanningService payload into OptimizerPort's ATOM-keyed shape" do
      legacy_payload = %{
        "days" => ["monday", "tuesday"],
        "slots" => ["breakfast", "lunch", "dinner"],
        "constraints" => %{
          "kcal_target" => 2100,
          "weekly_budget_cents" => 45_000,
          "account_type" => "individual",
          "subscription_tier" => "free",
          "inventory_items" => [],
          "macro_bounds" => %{
            "protein_g" => %{"min" => 100.0, "max" => 150.0}
          }
        },
        "candidates_by_slot" => %{
          "breakfast" => [%{"recipe_id" => "abc", "estimated_cost_cents" => 500}]
        }
      }

      translated = PythonOptimizerClient.to_optimizer_port_payload(legacy_payload)

      assert translated.days == ["monday", "tuesday"]
      assert translated.slots == ["breakfast", "lunch", "dinner"]
      assert translated.constraints == legacy_payload["constraints"]
      assert translated.candidates_by_slot == legacy_payload["candidates_by_slot"]
    end

    test "passes through an already ATOM-keyed payload unchanged (Generation.Server shape)" do
      atom_payload = %{
        days: ["2026-07-13"],
        slots: ["lunch"],
        constraints: %{weekly_budget_cents: 1000, macro_bounds: %{}},
        candidates_by_slot: %{"lunch" => []}
      }

      assert PythonOptimizerClient.to_optimizer_port_payload(atom_payload) == atom_payload
    end
  end

  describe "normalize_result/1" do
    test "wraps a raw JSON-decoded STRING-keyed solver response (real Python solver path) into an ATOM-keyed :meals map" do
      raw_solver_result =
        {:ok, %{"meals" => [%{"day" => "monday", "slot" => "lunch", "recipe_id" => "1"}]}}

      assert PythonOptimizerClient.normalize_result(raw_solver_result) ==
               {:ok, %{meals: [%{"day" => "monday", "slot" => "lunch", "recipe_id" => "1"}]}}
    end

    test "passes through an already ATOM-keyed result (circuit-breaker OptimizerFallback path) unchanged" do
      fallback_result =
        {:ok, %{meals: [%{"day" => "monday", "slot" => "lunch", "recipe_id" => nil}]}}

      assert PythonOptimizerClient.normalize_result(fallback_result) == fallback_result
    end

    test "passes through errors unchanged" do
      assert PythonOptimizerClient.normalize_result({:error, :optimizer_unavailable}) ==
               {:error, :optimizer_unavailable}
    end
  end
end
