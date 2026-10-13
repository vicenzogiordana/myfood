# Throwaway prototype for issue #88 (bounded planning loop). Not production code.
defmodule MealPlannerApi.PrototypePlanningLoop.Tools do
  @moduledoc """
  Tools exposed to the model. The household always comes from the session
  (`execute/3` argument), never from model-supplied arguments, and no tool
  schema carries a household id. Results are plain data handed back to the
  model; none of them grants validity except the validator verdict inside
  `present_proposal`.
  """

  alias MealPlannerApi.PrototypePlanningLoop.{Fixtures, Optimizer, Validator}

  @ask_human "ask_human"

  def ask_human_name, do: @ask_human

  @doc "Function tool definitions in the OpenAI Responses API shape."
  def definitions do
    meal = %{
      type: "object",
      properties: %{
        day: %{type: "string", enum: Fixtures.days()},
        slot: %{type: "string", enum: Fixtures.slots()},
        recipe_id: %{type: "string"}
      },
      required: ["day", "slot", "recipe_id"],
      additionalProperties: false
    }

    [
      function(
        "search_recipes",
        "Search the household recipe catalogue. Returns cost, macros per serving, ingredients and allergens.",
        %{
          slot: %{
            type: ["string", "null"],
            enum: Fixtures.slots() ++ [nil],
            description: "Meal slot filter, or null for all slots."
          },
          query: %{
            type: ["string", "null"],
            description:
              "Case-insensitive text matched against recipe name and ingredients, or null."
          }
        }
      ),
      function(
        "lookup_prices",
        "Look up the current price in cents per unit for ingredients.",
        %{ingredient_ids: %{type: "array", items: %{type: "string"}}}
      ),
      function(
        "run_optimizer",
        "Run the weekly meal optimizer for the session household. It fills every day and slot within budget and macro bounds. Pinned meals are forced into their day and slot; excluded recipes are never chosen.",
        %{
          pinned: %{
            type: "array",
            items: meal,
            description: "Meals the human explicitly asked for. Empty when none."
          },
          exclude_recipe_ids: %{type: "array", items: %{type: "string"}}
        }
      ),
      function(
        @ask_human,
        "Ask the human one question and wait for the answer. Use it whenever a request conflicts with a hard constraint or a decision belongs to the human. Ends your turn.",
        %{question: %{type: "string"}}
      ),
      function(
        "present_proposal",
        "Submit a full weekly plan for validation by code outside the model. Only a result with status \"valid\" has been shown to the human as a valid plan.",
        %{meals: %{type: "array", items: meal}, notes: %{type: "string"}}
      )
    ]
  end

  defp function(name, description, properties) do
    %{
      type: "function",
      name: name,
      description: description,
      strict: true,
      parameters: %{
        type: "object",
        properties: properties,
        required: properties |> Map.keys() |> Enum.map(&to_string/1),
        additionalProperties: false
      }
    }
  end

  @doc """
  Executes one tool call. Returns `{result, events}` where `result` is the
  JSON-encodable data fed back to the model and `events` are extra loop events
  (the validation verdict).
  """
  def execute("search_recipes", args, household) do
    query = args["query"] |> to_string() |> String.downcase()

    recipes =
      Fixtures.recipes()
      |> Enum.filter(&(is_nil(args["slot"]) or &1.slot == args["slot"]))
      |> Enum.filter(fn recipe ->
        haystack =
          String.downcase(
            Enum.join([recipe.id, recipe.name | Enum.map(recipe.ingredients, & &1.id)], " ")
          )

        query |> String.split() |> Enum.all?(&String.contains?(haystack, &1))
      end)
      |> Enum.map(&Map.put(&1, :ingredients_in_inventory, Fixtures.inventory_hits(household, &1)))

    {%{recipes: recipes}, []}
  end

  def execute("lookup_prices", args, _household) do
    prices =
      Map.new(List.wrap(args["ingredient_ids"]), fn id ->
        {id, Map.get(Fixtures.prices(), id, "unknown_ingredient")}
      end)

    {%{currency: "cents_per_unit", prices: prices}, []}
  end

  def execute("run_optimizer", args, household) do
    pinned = List.wrap(args["pinned"])
    excluded = List.wrap(args["exclude_recipe_ids"])

    case pin_problems(household, pinned) do
      [] -> {solve(household, pinned, excluded), []}
      problems -> {%{status: "pinned_conflict", solved: false, problems: problems}, []}
    end
  end

  def execute("present_proposal", args, household) do
    verdict = Validator.validate(household, args["meals"])

    result =
      if verdict.valid do
        %{status: "valid", shown_to_human: true, total_cost_cents: verdict.total_cost_cents}
      else
        %{status: "invalid", shown_to_human: false, violations: verdict.violations}
      end

    {result, [{:validation, verdict}]}
  end

  def execute(name, _args, _household),
    do: {%{status: "error", error: "unknown_tool", tool: name}, []}

  # A pin is refused before the solver runs when it is malformed or carries an
  # allergen of a member. The model is expected to take this to the human.
  defp pin_problems(household, pinned) do
    Enum.flat_map(pinned, fn
      pin when is_map(pin) -> pin_problems_for(household, pin, Fixtures.recipe(pin["recipe_id"]))
      other -> [%{problem: "malformed_pin", entry: inspect(other, limit: 5)}]
    end)
  end

  defp pin_problems_for(household, pin, recipe) do
    cond do
      is_nil(recipe) ->
        [%{problem: "unknown_recipe", recipe_id: pin["recipe_id"]}]

      recipe.slot != pin["slot"] or pin["day"] not in Fixtures.days() ->
        [
          %{
            problem: "recipe_not_for_day_or_slot",
            recipe_id: recipe.id,
            recipe_slot: recipe.slot
          }
        ]

      true ->
        for conflict <- Fixtures.allergen_conflicts(household, recipe) do
          %{
            problem: "allergen",
            recipe_id: recipe.id,
            recipe_name: recipe.name,
            member: conflict.member,
            allergen: conflict.allergen
          }
        end
    end
  end

  defp solve(household, pinned, excluded) do
    candidates_by_slot =
      Map.new(Fixtures.slots(), fn slot ->
        candidates =
          Fixtures.recipes()
          |> Enum.filter(&(&1.slot == slot and &1.id not in excluded))
          |> Enum.filter(&(Fixtures.allergen_conflicts(household, &1) == []))

        {slot, candidates}
      end)

    # The solver chooses per slot, not per day/slot cell, so it cannot pin.
    # Shortcut: solve every cell, overwrite the pinned cells afterwards, and
    # reserve budget for the price difference up front. Daily macro bounds are
    # not re-checked for pinned days.
    reserve =
      pinned
      |> Enum.map(fn pin ->
        cheapest =
          candidates_by_slot
          |> Map.fetch!(pin["slot"])
          |> Enum.map(& &1.cost_cents)
          |> Enum.min(fn -> 0 end)

        max(Fixtures.recipe(pin["recipe_id"]).cost_cents - cheapest, 0)
      end)
      |> Enum.sum()

    payload = %{
      days: Fixtures.days(),
      slots: Fixtures.slots(),
      constraints: %{
        weekly_budget_cents: household.weekly_budget_cents - reserve,
        macro_bounds: household.macro_bounds,
        inventory_weight: 100
      },
      candidates_by_slot:
        Map.new(candidates_by_slot, fn {slot, candidates} ->
          {slot, Enum.map(candidates, &candidate(household, &1))}
        end)
    }

    case Optimizer.solve(payload) do
      {:ok, %{"meals" => meals}} ->
        pins = Map.new(pinned, &{{&1["day"], &1["slot"]}, &1["recipe_id"]})

        meals =
          Enum.map(meals, fn meal ->
            Map.put(
              meal,
              "recipe_id",
              Map.get(pins, {meal["day"], meal["slot"]}, meal["recipe_id"])
            )
          end)

        total = meals |> Enum.map(&Fixtures.recipe(&1["recipe_id"]).cost_cents) |> Enum.sum()

        %{
          status: "solution",
          solved: true,
          meals: meals,
          total_cost_cents: total,
          weekly_budget_cents: household.weekly_budget_cents
        }

      {:error, error} ->
        Map.merge(%{status: "error", solved: false}, error)
    end
  end

  defp candidate(household, recipe) do
    %{
      recipe_id: recipe.id,
      label: recipe.name,
      estimated_cost_cents: recipe.cost_cents,
      calories_per_serving: recipe.calories,
      protein_g_per_serving: recipe.protein_g,
      carbs_g_per_serving: recipe.carbs_g,
      fat_g_per_serving: recipe.fat_g,
      inventory_hit_count: Fixtures.inventory_hits(household, recipe)
    }
  end
end
