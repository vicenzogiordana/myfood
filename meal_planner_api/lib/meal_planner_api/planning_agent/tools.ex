defmodule MealPlannerApi.PlanningAgent.Tools do
  @moduledoc """
  Agent-callable tool catalog of the planning agent (spec #93). No tool writes
  persistent data.

    * `search_recipes` — structured search; Restriction-violating recipes are
      excluded by code
    * `get_workspace` — the current Workspace: Proposal, draft, Pins,
      Excluded Recipes, Released Meals and variety cap
    * `edit_workspace` — Pin, unpin, exclude, include, release meals and set
      the variety cap; invalid edits are refused with a reason and approvals
      can never be set
    * `run_optimizer` — the existing optimizer over Restriction-safe
      candidates; it keeps every Pin and, once a Proposal exists, every meal
      that was not released. Failures are typed errors, never a fallback plan
    * `present_proposal` — always validates the latest optimizer plan; only a
      valid plan is shown to the Member, otherwise violations go back
    * `ask_human` — one question; ends the turn

  Every call runs with the session's tool context. The Household always comes
  from that context: tool schemas carry no Household and any Household named
  in model arguments is ignored. Unknown tools are rejected by code.
  """

  alias MealPlannerApi.Optimization.Variety
  alias MealPlannerApi.PlanningAgent.{ProposalValidator, RecipeSearch, Workspace}

  @type context :: %{
          required(:account_id) => Ecto.UUID.t(),
          required(:range) => {Date.t(), Date.t()},
          required(:slots) => [String.t()],
          required(:household) => map(),
          required(:workspace) => Workspace.t(),
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
        name: "get_workspace",
        description:
          "Read the current Workspace: last Proposal, draft plan, Pins, Excluded Recipes, " <>
            "Released Meals and variety cap.",
        parameters: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      },
      %{
        name: "edit_workspace",
        description:
          "Edit the Workspace with one action. pin: fix a recipe to a date and slot " <>
            "(omit recipe_id to keep the proposed meal). unpin: remove a Pin. exclude / include: " <>
            "add or remove an Excluded Recipe. release: let the next run_optimizer change one " <>
            "meal of the last Proposal (release only the meals the household mentioned; ask " <>
            "before releasing more). release_all: redo every meal that is not pinned (Pins last for the session). " <>
            "set_variety_cap: how many times a recipe may appear in any 7 days. " <>
            "Approvals and confirmations are never possible here. Refused edits return a reason.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ~w(pin unpin exclude include release release_all set_variety_cap)
            },
            "date" => %{"type" => "string", "description" => "ISO date inside the range"},
            "slot" => %{"type" => "string"},
            "recipe_id" => %{"type" => "string"},
            "variety_cap" => %{"type" => "integer", "minimum" => 1}
          },
          "required" => ["action"],
          "additionalProperties" => false
        }
      },
      %{
        name: "run_optimizer",
        description:
          "Build a plan for every day and slot of the Planning Range with the optimizer. " <>
            "Pins and every meal of the last Proposal that was not released stay fixed. " <>
            "Optionally exclude more recipes for this run. Returns the plan with its " <>
            "Deviations or a typed error.",
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

  def execute("get_workspace", _args, ctx),
    do: {Workspace.to_data(ctx.workspace, ctx), ctx.workspace, :continue}

  def execute("edit_workspace", args, ctx) do
    case Workspace.edit(ctx.workspace, args, ctx) do
      {:ok, workspace, result} ->
        {result, workspace, :continue}

      {:error, code, extra} ->
        {Map.merge(%{"error" => code, "reason" => Workspace.reason(code)}, extra), ctx.workspace,
         :continue}
    end
  end

  def execute("run_optimizer", args, ctx) do
    emit(ctx, %{"type" => "progress", "step" => "running_optimizer"})

    exclude =
      args
      |> Map.get("exclude_recipe_ids", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.concat(MapSet.to_list(ctx.workspace.excluded))
      |> Enum.uniq()

    fixed = Workspace.fixed_meals(ctx.workspace)

    with {:ok, candidates_by_slot} <- candidates(ctx, exclude),
         {:ok, candidates_by_slot} <- with_fixed_candidates(ctx, candidates_by_slot, fixed),
         {:ok, payload} <- payload(ctx, candidates_by_slot, exclude, fixed),
         {:ok, solution} <- solve(ctx, payload),
         :ok <- keeps_fixed(solution.meals, fixed) do
      names =
        candidates_by_slot
        |> Map.values()
        |> List.flatten()
        |> Map.new(&{&1["recipe_id"], &1["label"]})

      workspace = %{ctx.workspace | draft: solution.meals}

      result =
        %{"status" => "ok", "meals" => Enum.map(solution.meals, &meal_data(&1, names))}
        |> Map.merge(solution.extra)

      {result, workspace, :continue}
    else
      # Every failed run discards the earlier draft so present_proposal cannot
      # show a plan the agent just asked to change.
      {:error, :no_candidates, slot} ->
        {%{"error" => "no_candidates", "slot" => slot}, %{ctx.workspace | draft: nil}, :continue}

      {:error, :search_failed} ->
        {%{"error" => "search_failed"}, %{ctx.workspace | draft: nil}, :continue}

      {:error, :fixed_meal_unavailable, meal} ->
        {%{"error" => "fixed_meal_unavailable", "meal" => meal}, %{ctx.workspace | draft: nil},
         :continue}

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
         Workspace.present(ctx.workspace, proposal, meals), :continue}

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

  # A fixed meal's recipe may fall outside the searched candidates of its
  # slot; it is added so the optimizer can keep it. A recipe that now violates
  # a Restriction is flagged, so the optimizer refuses it instead of keeping it.
  defp with_fixed_candidates(_ctx, candidates_by_slot, []), do: {:ok, candidates_by_slot}

  defp with_fixed_candidates(ctx, candidates_by_slot, fixed) do
    case RecipeSearch.lookup(ctx.household, fixed |> Enum.map(& &1.recipe_id) |> Enum.uniq()) do
      {:ok, found} ->
        Enum.reduce_while(fixed, {:ok, candidates_by_slot}, fn meal, {:ok, acc} ->
          case Map.fetch(found, meal.recipe_id) do
            {:ok, {status, recipe}} ->
              {:cont, {:ok, put_candidate(acc, meal.slot, recipe, status)}}

            :error ->
              {:halt, {:error, :fixed_meal_unavailable, meal_key_data(meal)}}
          end
        end)

      {:error, :search_failed} = error ->
        error
    end
  end

  defp put_candidate(candidates_by_slot, slot, recipe, status) do
    candidates = Map.get(candidates_by_slot, slot, [])

    candidates =
      cond do
        status == :restricted ->
          [Map.put(candidate(recipe), "violates_restriction", true)] ++
            Enum.reject(candidates, &(&1["recipe_id"] == recipe.id))

        Enum.any?(candidates, &(&1["recipe_id"] == recipe.id)) ->
          candidates

        true ->
          candidates ++ [candidate(recipe)]
      end

    Map.put(candidates_by_slot, slot, candidates)
  end

  defp payload(ctx, candidates_by_slot, exclude, fixed) do
    {from_date, to_date} = ctx.range

    payload = %{
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
      "candidates_by_slot" => candidates_by_slot,
      "excluded_recipe_ids" => exclude,
      "fixed_meals" => Enum.map(fixed, &meal_key_data/1)
    }

    prior = Variety.prior_meals(ctx.account_id, from_date)

    case Variety.put(payload, prior, ctx.workspace.variety_cap) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  # Code, not the optimizer's word, guarantees that a re-optimization changes
  # only Released Meals.
  defp keeps_fixed(meals, fixed) do
    planned = Map.new(meals, &{{&1.date, &1.slot}, &1.recipe_id})

    if Enum.all?(fixed, &(Map.get(planned, {&1.date, &1.slot}) == &1.recipe_id)),
      do: :ok,
      else: {:error, :fixed_meal_moved, %{}}
  end

  defp solve(ctx, payload) do
    {optimizer, opts} = optimizer(ctx)

    case optimizer.solve(payload, opts) do
      {:ok, %{"meals" => meals} = result} when is_list(meals) ->
        with {:ok, parsed} <- parse_meals(meals) do
          {:ok, %{meals: parsed, extra: Map.take(result, ["deviations", "optimality"])}}
        end

      {:ok, _other} ->
        {:error, :invalid_optimizer_response, %{}}

      {:error, reason, details} ->
        {:error, reason, details}
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

  defp meal_key_data(meal),
    do: %{"day" => Date.to_iso8601(meal.date), "slot" => meal.slot, "recipe_id" => meal.recipe_id}

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
