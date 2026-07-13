defmodule MealPlannerApi.Generation.PipelineCandidatesTest do
  @moduledoc """
  TDD coverage for item 1 (planning-pipeline-plumbing): `Generation.Server`
  used to hardcode `"available_recipe_ids" => []` for every slot in
  `build_slots_input/3`, so `candidates_by_slot` sent to the optimizer was
  always empty regardless of how many qualifying recipes existed.

  This exercises the REAL production functions (`Server.build_slots_input/3`,
  `Server.load_recipe_macros/1`, `PayloadAdapter.build_optimizer_payload/3`)
  end-to-end up to — but not including — the live Python solver call. The
  solver itself (`OptimizerServer`, a Port-based GenServer around
  `ortools`/`optimizador.py`) is out of scope here: this dev sandbox doesn't
  have `ortools` installed (pre-existing, unrelated to this fix — confirmed
  via `python3 -c "import ortools"` failing and Homebrew's PEP 668 guard
  blocking a global `pip install` without `--break-system-packages`), so a
  live-solver integration test would be an environment-flakiness risk, not a
  meaningful assertion about this bug. The confirm-path tests (item 3)
  exercise the same GenServer/broadcast/supervisor plumbing end-to-end
  without needing the solver.
  """

  use MealPlannerApiWeb.ChannelCase, async: false

  alias MealPlannerApi.Generation.Server
  alias MealPlannerApi.Optimization.PayloadAdapter
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Services.PriceService

  import MealPlannerApi.FactoryHelpers

  @slot_types ["breakfast", "lunch", "dinner"]

  test "build_slots_input wires real, non-empty candidates per slot when a qualifying recipe exists" do
    user =
      user_with_memberships(%{email: "candidates@example.com"}, [{%{plan: :individual}, :owner}])

    [membership] = user.memberships
    account = membership.account

    {:ok, recipe} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: "Only Candidate",
        source: :user_created,
        servings: 1,
        suitable_for_slots: @slot_types,
        protein_g_per_serving: 25,
        calories_per_serving: 800,
        carbs_g_per_serving: 75,
        fat_g_per_serving: 10
      })

    today = Date.utc_today() |> Date.to_iso8601()

    constraints = %{
      "date_from" => today,
      "date_to" => today,
      "slot_types" => @slot_types
    }

    slots_input = Server.build_slots_input(constraints, account.id, user.id)

    assert length(slots_input) == length(@slot_types)

    assert Enum.all?(slots_input, fn slot ->
             slot.available_recipe_ids == [to_string(recipe.id)]
           end),
           "expected every slot to carry the real qualifying recipe id, got: #{inspect(slots_input)}"

    all_recipe_ids =
      slots_input
      |> Enum.flat_map(&(&1[:available_recipe_ids] || []))
      |> Enum.uniq()

    recipe_prices = PriceService.fetch_recipe_prices_float(all_recipe_ids)
    recipe_macros = Server.load_recipe_macros(all_recipe_ids)

    optimizer_payload =
      PayloadAdapter.build_optimizer_payload(
        slots_input,
        stringify_keys(recipe_prices),
        stringify_keys(recipe_macros)
      )

    refute optimizer_payload.candidates_by_slot == %{},
           "candidates_by_slot must not be empty when a qualifying recipe exists"

    for slot_type <- @slot_types do
      candidates = optimizer_payload.candidates_by_slot[slot_type]
      assert is_list(candidates) and candidates != [], "slot #{slot_type} has no candidates"
      assert Enum.any?(candidates, &(&1.recipe_id == to_string(recipe.id)))
    end
  end

  defp stringify_keys(map) do
    map |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Enum.into(%{})
  end
end
