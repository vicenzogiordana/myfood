# SDD DESIGN — python-integration-fix

## Architecture

```
                    GenerationServer.run_pipeline()
                              │
                              ▼
                    ┌─────────────────────┐
                    │  build_slots_input  │
                    │  PriceService       │
                    │  fetch_recipe_prices │
                    └─────────┬───────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │ PayloadAdapter     │
                    │ .build_optimizer_   │
                    │ payload/3           │
                    │ (TRANSLATION)       │
                    └─────────┬───────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │ OptimizerServer     │
                    │ .select_weekly_menu │
                    │ (Port/stdio, works) │
                    └─────────┬───────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │ optimizador.py      │
                    │ (OR-Tools)          │
                    └─────────┬───────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │ PayloadAdapter     │
                    │ .translate_response│
                    │ /2                  │
                    │ (TRANSLATION)       │
                    └─────────┬───────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │ load_recipe_data   │
                    │ (DB lookup)         │
                    └─────────┬───────────┘
                              │
                              ▼
                    GenerationServer.proposal_json
```

## Implementation Details

### 1. PayloadAdapter.build_optimizer_payload/3

```elixir
defmodule MealPlannerApi.Optimization.PayloadAdapter do
  @doc """
  Translates Generation pipeline format to OptimizerServer format.
  """
  def build_optimizer_payload(slots, recipe_prices, recipe_macros) do
    # Extract unique days and slot types
    days = slots |> Enum.map(& &1.date) |> Enum.uniq()
    slot_types = slots |> Enum.map(&to_string(&1.slot)) |> Enum.uniq()

    # Build constraints (weekly aggregate)
    first_constraints = slots |> List.first() |> Map.get(:constraints, %{})
    weekly_budget = compute_weekly_budget(slots)
    macro_bounds = compute_macro_bounds(slots)

    # Build candidates_by_slot
    candidates_by_slot = build_candidates_by_slot(slots, recipe_prices, recipe_macros)

    %{
      days: days,
      slots: slot_types,
      constraints: %{
        weekly_budget_cents: weekly_budget,
        macro_bounds: macro_bounds
      },
      candidates_by_slot: candidates_by_slot
    }
  end

  defp compute_weekly_budget(slots) do
    slots
    |> Enum.flat_map(fn slot ->
      case slot.constraints do
        %{budget_cents: budget} -> [budget]
        %{"budget_cents" => budget} -> [budget]
        _ -> []
      end
    end)
    |> case do
      [] -> 50_000  # default: 500 USD/week
      budgets -> Enum.sum(budgets)
    end
  end

  defp compute_macro_bounds(slots) do
    # Sum per-slot constraints for weekly bounds
    totals = slots |> Enum.reduce({0, 0, 0}, fn slot, {p, c, f} ->
      constraints = slot.constraints || %{}
      protein = constraints[:protein_g] || constraints["protein_g"] || 25
      carbs = protein * 3  # default: 3x protein
      fat = protein * 0.4  # default: 40% of protein
      {p + protein, c + carbs, f + fat}
    end)

    {protein_sum, carbs_sum, fat_sum} = totals
    %{
      protein_g: %{min: protein_sum * 0.7, max: protein_sum * 1.3},
      carbs_g: %{min: carbs_sum * 0.7, max: carbs_sum * 1.3},
      fat_g: %{min: fat_sum * 0.7, max: fat_sum * 1.3}
    }
  end

  defp build_candidates_by_slot(slots, recipe_prices, recipe_macros) do
    slots
    |> Enum.group_by(fn slot -> to_string(slot.slot) end)
    |> Enum.into(%{}, fn {slot_type, slot_group} ->
      # Collect all recipe IDs from all slots of this type, deduplicate
      recipe_ids = slot_group
        |> Enum.flat_map(fn slot -> slot.available_recipe_ids || [] end)
        |> Enum.uniq()

      # Build candidate list with price and macros
      candidates = Enum.map(recipe_ids, fn recipe_id ->
        price = Map.get(recipe_prices, recipe_id, 0.0)
        macros = Map.get(recipe_macros, recipe_id, %{protein_g: 25, calories: 450, carbs_g: 30})

        %{
          recipe_id: recipe_id,
          estimated_cost_cents: round(price * 100),
          protein_g_per_serving: macros[:protein_g] || 25,
          carbs_g_per_serving: macro_estimate(macros, :carbs_g),
          fat_g_per_serving: macro_estimate(macros, :fat)
        }
      end)

      {slot_type, candidates}
    end)
  end

  defp macro_estimate(macros, :carbs_g) do
    # Use carbs_g if available, else estimate from calories: carbs = calories / 4
    case macros do
      %{carbs_g: v} -> v
      %{carbs: v} -> v
      %{calories: cal} -> cal / 4
      _ -> 75  # default
    end
  end

  defp macro_estimate(macros, :fat) do
    # Use fat if available, else estimate: fat = protein * 0.4
    case macros do
      %{fat_g: v} -> v
      %{fat: v} -> v
      %{protein_g: p} -> p * 0.4
      _ -> 10  # default
    end
  end
end
```

### 2. PayloadAdapter.translate_response/2

```elixir
def translate_response({:ok, %{meals: meals}}, recipe_data) do
  Enum.map(meals, fn %{day: day, slot: slot, recipe_id: recipe_id} ->
    recipe = Map.get(recipe_data, recipe_id, %{})

    %{
      date: day,
      slot: slot,
      recipe_id: recipe_id,
      recipe_name: Map.get(recipe, :name, "Unknown Recipe"),
      price_cents: Map.get(recipe, :price_cents, 0),
      macros: %{
        protein_g: Map.get(recipe, :protein_g, 0),
        calories: Map.get(recipe, :calories, 0),
        carbs_g: Map.get(recipe, :carbs_g, 0)
      }
    }
  end)
end

def translate_response({:error, reason}, _recipe_data) do
  {:error, reason}
end
```

### 3. GenerationServer changes

**Add to imports:**
```elixir
alias MealPlannerApi.Optimization.PayloadAdapter
alias MealPlannerApi.Optimization.OptimizerServer
```

**Update run_pipeline/1:**
```elixir
# Before (dead code):
case PythonClient.optimize_menu(slots_input, recipe_prices, recipe_macros) do
  {:ok, optimized_slots} -> ...

# After (working):
optimizer_payload = PayloadAdapter.build_optimizer_payload(slots_input, recipe_prices, recipe_macros)
recipe_data = load_recipe_data_for_response(all_recipe_ids)

case OptimizerServer.select_weekly_menu(optimizer_payload) do
  {:ok, optimizer_result} ->
    optimized_slots = PayloadAdapter.translate_response({:ok, optimizer_result}, recipe_data)
    proposal_json = GenerationService.build_proposal_json(optimized_slots)
    ...
```

**Add new helper:**
```elixir
defp load_recipe_data_for_response(recipe_ids) do
  recipe_ids
  |> RecipeRepo.list_by_ids_with_prices()
  |> Enum.into(%{}, fn recipe ->
    {to_string(recipe.id), %{
      name: recipe.name,
      price_cents: (recipe.recipe_price && recipe.recipe_price.price_per_serving_cents) || 0,
      protein_g: recipe.protein_g_per_serving || 0,
      calories: recipe.calories_per_serving || 0,
      carbs_g: recipe.carbs_g_per_serving || 0
    }}
  end)
end
```

## Files to Change

| File | Change | Lines |
|------|--------|-------|
| `lib/meal_planner_api/optimization/payload_adapter.ex` | New module | ~120 |
| `lib/meal_planner_api/generation/server.ex` | Replace PythonClient call, add helper | ~30 |
| `lib/meal_planner_api/data/recipe_repo.ex` | Add list_by_ids_with_prices/1 | ~10 |
| `test/meal_planner_api/optimization/payload_adapter_test.exs` | New test file | ~120 |
| `test/meal_planner_api/generation/server_test.exs` | Update mocks | ~20 |

**Total: ~300 lines** — under 400-line threshold, single PR.

## Testing Strategy

1. **Unit tests for PayloadAdapter** (RED → GREEN):
   - Test `build_optimizer_payload/3` with various inputs
   - Test `translate_response/2` with valid and error responses

2. **Update existing GenerationServer tests**:
   - Change mock from `PythonClient` to `OptimizerServer`
   - Add assertions for response format

3. **Regression tests**:
   - Run full test suite to ensure no breakage
   - Verify `PlanningService` still works

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| GenerationServer state machine broken | Adapter approach keeps state machine unchanged |
| Macro bounds miscalculated | Document conversion (per-slot → weekly); add integration test |
| Recipe data lookup fails | Use defaults (0 for missing price/macros, "Unknown Recipe" for name) |
| OptimizerServer circuit breaker activates | Fallback to `OptimizerFallback` (existing behavior) |