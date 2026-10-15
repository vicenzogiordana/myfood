defmodule MealPlannerApi.PlanningAgent.Tools do
  @moduledoc """
  Agent-callable tool catalog of the planning agent (spec #93). No tool writes
  persistent data.

    * `search_recipes` — structured search; Restriction-violating recipes are
      excluded by code
    * `run_optimizer` — the existing optimizer over Restriction-safe candidates;
      failures are typed errors, never a fallback plan
    * `present_proposal` — always validates the latest optimizer plan; only a
      valid plan is shown to the Member, otherwise violations go back
    * `ask_human` — one question; ends the turn

  Every call runs with the session's tool context. The Household always comes
  from that context: tool schemas carry no Household and any Household named
  in model arguments is ignored. Unknown tools are rejected by code.
  """

  alias MealPlannerApi.PlanningAgent.{ProposalValidator, RecipeSearch}

  @type context :: %{
          required(:account_id) => Ecto.UUID.t(),
          required(:range) => {Date.t(), Date.t()},
          required(:slots) => [String.t()],
          required(:household) => map(),
          required(:workspace) => map(),
          optional(atom()) => term()
        }

  @type control :: :continue | :end_turn

  @optimizer_candidates_per_slot 50
  @wide_bounds %{"min" => 0, "max" => 1_000_000}

  @doc "Tool definitions offered to the model."
  @spec definitions() :: [MealPlannerApi.PlanningAgent.Model.tool()]
  def definitions do
    [
      %{
        name: "search_recipes",
        description:
          "Search recipes by text over name and ingredients, optionally filtered by meal slot " <>
            "and ingredient. Recipes violating household Restrictions are already excluded.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Text to match"},
            "slot" => %{"type" => "string", "description" => "Meal slot, e.g. lunch"},
            "ingredient" => %{"type" => "string", "description" => "Ingredient name to require"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          },
          "additionalProperties" => false
        }
      },
      %{
        name: "run_optimizer",
        description:
          "Build a plan for every day and slot of the Planning Range with the optimizer. " <>
            "Optionally exclude recipes. Returns the plan or a typed error.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "exclude_recipe_ids" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "additionalProperties" => false
        }
      },
      %{
        name: "present_proposal",
        description:
          "Validate the latest optimizer plan and, only if valid, show it to the household. " <>
            "Returns the validity status or the violations to fix.",
        parameters: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      },
      %{
        name: "ask_human",
        description: "Ask the household one question. Ends your turn.",
        parameters: %{
          "type" => "object",
          "properties" => %{"question" => %{"type" => "string"}},
          "required" => ["question"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @doc """
  Executes one tool call. Returns the tool result content, the possibly
  updated workspace, and whether the turn continues.
  """
  @spec execute(String.t(), map(), context()) :: {map(), map(), control()}
  def execute("search_recipes", args, ctx) do
    emit(ctx, %{"type" => "progress", "step" => "searching_recipes"})

    filters = %{
      query: string_arg(args, "query"),
      slot: string_arg(args, "slot"),
      ingredient: string_arg(args, "ingredient"),
      limit: integer_arg(args, "limit")
    }

    case RecipeSearch.search(ctx.household, reject_nil(filters)) do
      {:ok, recipes} ->
        {%{"recipes" => Enum.map(recipes, &recipe_data/1)}, ctx.workspace, :continue}

      {:error, :search_failed} ->
        {%{"error" => "search_failed"}, ctx.workspace, :continue}
    end
  end

  def execute("run_optimizer", args, ctx) do
    emit(ctx, %{"type" => "progress", "step" => "running_optimizer"})

    exclude =
      args |> Map.get("exclude_recipe_ids", []) |> List.wrap() |> Enum.filter(&is_binary/1)

    with {:ok, candidates_by_slot} <- candidates(ctx, exclude),
         payload = payload(ctx, candidates_by_slot),
         {:ok, meals} <- solve(ctx, payload) do
      names =
        candidates_by_slot
        |> Map.values()
        |> List.flatten()
        |> Map.new(&{&1["recipe_id"], &1["label"]})

      workspace = %{ctx.workspace | draft: meals}

      {%{"status" => "ok", "meals" => Enum.map(meals, &meal_data(&1, names))}, workspace,
       :continue}
    else
      {:error, :no_candidates, slot} ->
        {%{"error" => "no_candidates", "slot" => slot}, ctx.workspace, :continue}

      {:error, :search_failed} ->
        {%{"error" => "search_failed"}, ctx.workspace, :continue}

      {:error, reason, details} ->
        reason = reason_string(reason)
        emit(ctx, %{"type" => "optimizer_failed", "reason" => reason})

        {%{"error" => "optimizer_failed", "reason" => reason, "details" => details},
         %{ctx.workspace | draft: nil}, :continue}
    end
  end

  def execute("present_proposal", _args, %{workspace: %{draft: nil}} = ctx),
    do: {%{"error" => "no_plan_to_present"}, ctx.workspace, :continue}

  def execute("present_proposal", _args, ctx) do
    emit(ctx, %{"type" => "progress", "step" => "validating_proposal"})

    case ProposalValidator.validate(ctx.workspace.draft, ctx) do
      {:valid, meals} ->
        proposal = %{
          "type" => "proposal",
          "proposal_id" => Ecto.UUID.generate(),
          "status" => "valid",
          "meals" =>
            Enum.map(meals, fn meal ->
              %{
                "date" => Date.to_iso8601(meal.date),
                "slot" => meal.slot,
                "recipe_id" => meal.recipe_id,
                "name" => meal.name
              }
            end)
        }

        emit(ctx, proposal)

        {%{"status" => "valid", "proposal_id" => proposal["proposal_id"]},
         %{ctx.workspace | proposal: proposal}, :continue}

      {:invalid, violations} ->
        {%{"status" => "invalid", "violations" => violations}, ctx.workspace, :continue}
    end
  end

  def execute("ask_human", args, ctx) do
    case string_arg(args, "question") do
      nil ->
        {%{"error" => "question_required"}, ctx.workspace, :continue}

      question ->
        emit(ctx, %{"type" => "question", "text" => question})
        {%{"status" => "asked"}, ctx.workspace, :end_turn}
    end
  end

  def execute(_name, _arguments, ctx),
    do: {%{"error" => "unknown_tool"}, ctx.workspace, :continue}

  # ---------------------------------------------------------------------------
  # Optimizer
  # ---------------------------------------------------------------------------

  defp candidates(ctx, exclude) do
    Enum.reduce_while(ctx.slots, {:ok, %{}}, fn slot, {:ok, acc} ->
      filters = %{slot: slot, exclude_recipe_ids: exclude, limit: @optimizer_candidates_per_slot}

      case RecipeSearch.search(ctx.household, filters) do
        {:ok, []} -> {:halt, {:error, :no_candidates, slot}}
        {:ok, recipes} -> {:cont, {:ok, Map.put(acc, slot, Enum.map(recipes, &candidate/1))}}
        {:error, :search_failed} = error -> {:halt, error}
      end
    end)
  end

  # Candidate costs and the Nutrition Goal enter the optimizer with the
  # package-aware purchase calculation and goal relaxation slices of #93; the
  # tracer bullet keeps bounds wide so only coverage decides feasibility.
  defp candidate(recipe) do
    %{
      "recipe_id" => recipe.id,
      "label" => recipe.name,
      "estimated_cost_cents" => 0,
      "calories_per_serving" => recipe.calories_per_serving || 0,
      "protein_g_per_serving" => recipe.protein_g_per_serving || 0,
      "carbs_g_per_serving" => recipe.carbs_g_per_serving || 0,
      "fat_g_per_serving" => recipe.fat_g_per_serving || 0,
      "inventory_hit_count" => 0
    }
  end

  defp payload(ctx, candidates_by_slot) do
    {from_date, to_date} = ctx.range

    %{
      "days" => from_date |> Date.range(to_date) |> Enum.map(&Date.to_iso8601/1),
      "slots" => ctx.slots,
      "constraints" => %{
        "weekly_budget_cents" => ctx.household.budget_cents,
        "macro_bounds" => %{
          "protein_g" => @wide_bounds,
          "carbs_g" => @wide_bounds,
          "fat_g" => @wide_bounds,
          "calories" => @wide_bounds
        }
      },
      "candidates_by_slot" => candidates_by_slot
    }
  end

  defp solve(ctx, payload) do
    {optimizer, opts} = optimizer(ctx)

    case optimizer.solve(payload, opts) do
      {:ok, %{"meals" => meals}} when is_list(meals) -> parse_meals(meals)
      {:ok, _other} -> {:error, :invalid_optimizer_response, %{}}
      {:error, reason, details} -> {:error, reason, details}
    end
  end

  defp optimizer(%{optimizer: {module, opts}}), do: {module, opts}
  defp optimizer(%{optimizer: module}) when is_atom(module) and module != nil, do: {module, []}
  defp optimizer(_ctx), do: {MealPlannerApi.PlanningAgent.Optimizer.Unavailable, []}

  defp parse_meals(meals) do
    Enum.reduce_while(meals, {:ok, []}, fn
      %{"day" => day, "slot" => slot, "recipe_id" => recipe_id}, {:ok, acc}
      when is_binary(day) and is_binary(slot) and is_binary(recipe_id) ->
        case Date.from_iso8601(day) do
          {:ok, date} -> {:cont, {:ok, [%{date: date, slot: slot, recipe_id: recipe_id} | acc]}}
          _ -> {:halt, {:error, :invalid_optimizer_response, %{}}}
        end

      _meal, _acc ->
        {:halt, {:error, :invalid_optimizer_response, %{}}}
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp recipe_data(recipe) do
    %{
      "recipe_id" => recipe.id,
      "name" => recipe.name,
      "slots" => recipe.slots,
      "ingredients" => recipe.ingredients,
      "calories_per_serving" => recipe.calories_per_serving
    }
  end

  defp meal_data(meal, names) do
    %{
      "date" => Date.to_iso8601(meal.date),
      "slot" => meal.slot,
      "recipe_id" => meal.recipe_id,
      "name" => Map.get(names, meal.recipe_id)
    }
  end

  defp string_arg(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp integer_arg(args, key) do
    case Map.get(args, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp reject_nil(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

  defp emit(%{emit: emit}, event) when is_function(emit, 1), do: emit.(event)
  defp emit(_ctx, _event), do: :ok

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(_reason), do: "optimizer_error"
end
