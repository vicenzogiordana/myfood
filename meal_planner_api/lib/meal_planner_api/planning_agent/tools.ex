defmodule MealPlannerApi.PlanningAgent.Tools do
  @moduledoc """
  Agent-callable tool catalog of the planning agent (spec #93). No tool writes
  persistent data.

    * `search_recipes` — structured search; Restriction-violating recipes are
      excluded by code
    * `get_plan` — the Household's Planned Meals by date or range (planned,
      not eaten)
    * `reuse_plan` — a past stretch of the Meal Plan as the new draft; it
      must pass `present_proposal` like any optimizer plan
    * `run_optimizer` — the existing optimizer over Restriction-safe candidates;
      failures are typed errors, never a fallback plan
    * `get_pantry` — the Projected Pantry (Pantry minus stock committed to
      not-yet-cooked Planned Meals)
    * `lookup_prices` — stored prices with provenance; missing prices are
      reported, never invented
    * `get_recipe` — one recipe or Recipe Draft with ingredients,
      quantities, steps, nutrition and its completeness
    * `create_recipe` — a Recipe Draft from catalog Ingredients only, kept in
      the Workspace (`MealPlannerApi.PlanningAgent.RecipeDraft`); unknown
      Ingredients are rejected and nutrition and cost are computed by code
    * `present_proposal` — always validates the latest optimizer plan; only a
      valid plan is shown to the Member, otherwise violations go back. A
      shown Proposal always carries its Purchase (`MealPlannerApi.PlanningAgent.Purchase`),
      the consumed-ingredient cost and the budget comparison; a Purchase
      over the budget is a budget Deviation (`requires_approval`)
    * `ask_human` — one question; ends the turn

  Read calls (recipe search) and solver calls run within
  `MealPlannerApi.PlanningAgent.CallBounds`: their own deadline and retry
  budget, clipped by the turn's global deadline.

  Every call runs with the session's tool context. The Household always comes
  from that context: tool schemas carry no Household and any Household named
  in model arguments is ignored. Unknown tools are rejected by code.
  """

  alias MealPlannerApi.PlanningAgent.{
    CallBounds,
    MealPlan,
    Prices,
    ProjectedPantry,
    Proposal,
    ProposalValidator,
    RecipeDraft,
    RecipeSearch
  }

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
  @max_price_lookups 50
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
        name: "get_recipe",
        description:
          "Read one recipe or Recipe Draft by id: ingredients with quantities (milli-units), " <>
            "steps, nutrition per serving and whether that nutrition is complete, and its " <>
            "Recipe Origin.",
        parameters: %{
          "type" => "object",
          "properties" => %{"recipe_id" => %{"type" => "string"}},
          "required" => ["recipe_id"],
          "additionalProperties" => false
        }
      },
      %{
        name: "create_recipe",
        description:
          "Draft a new recipe when existing recipes do not fit, or build the recipe a Member " <>
            "dictates (origin user_created). Use catalog Ingredient names only: unknown " <>
            "Ingredients reject the Draft. Nutrition and cost are computed by code and " <>
            "reported partial when data is missing. The Draft lives only in this chat; it is " <>
            "never saved by you. AI-created Drafts can be planned; a dictated recipe is saved " <>
            "only when the Member presses save.",
        parameters: RecipeDraft.parameters()
      },
      %{
        name: "get_plan",
        description:
          "Read the household's confirmed Planned Meals for one date or an inclusive range " <>
            "(at most #{MealPlan.max_range_days()} days). Reports what was planned, not what " <>
            "was eaten.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "from" => %{"type" => "string", "description" => "First date, YYYY-MM-DD"},
            "to" => %{
              "type" => "string",
              "description" => "Last date, YYYY-MM-DD; defaults to from"
            }
          },
          "required" => ["from"],
          "additionalProperties" => false
        }
      },
      %{
        name: "reuse_plan",
        description:
          "Use the Planned Meals of a past stretch, starting at source_from and as long as " <>
            "the Planning Range, as the new draft (e.g. repeat the week before last). Only " <>
            "day, slot and recipe are copied; call present_proposal to validate and show it.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "source_from" => %{
              "type" => "string",
              "description" => "First past date to copy, YYYY-MM-DD, before the Planning Range"
            }
          },
          "required" => ["source_from"],
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
        name: "get_pantry",
        description:
          "Read the household's Projected Pantry: stock on hand minus what is already " <>
            "committed to Planned Meals not yet cooked. Quantities are milli-units.",
        parameters: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      },
      %{
        name: "lookup_prices",
        description:
          "Read stored prices of the Products covering the named ingredients, with product, " <>
            "presentation, supermarket, currency and observation date. Ingredients without a " <>
            "stored price are listed as missing; never assume a price for them.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "ingredients" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "minItems" => 1,
              "maxItems" => @max_price_lookups,
              "description" => "Ingredient names, as returned by search_recipes"
            }
          },
          "required" => ["ingredients"],
          "additionalProperties" => false
        }
      },
      %{
        name: "present_proposal",
        description:
          "Validate the latest optimizer plan and, only if valid, show it to the household " <>
            "with its Purchase (packages to buy net of the Projected Pantry) and budget check. " <>
            "Returns the status (valid, requires_approval with Deviations) or the violations to fix.",
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
  def execute(name, args, ctx) do
    {content, workspace, control} = run(name, args, ctx)
    {Map.put_new(content, "outcome", outcome(content)), workspace, control}
  end

  @doc """
  The outcome kind of a tool result: `complete`, `partial` (verified but
  with missing data, named under `"missing"`), `failure`, or `unknown` (the
  call was cut by its deadline, so absence of a result proves nothing).
  `cancelled` applies only to runs, which a cancel interrupts mid-tool.
  """
  @spec outcome(map()) :: String.t()
  def outcome(%{"outcome" => outcome}), do: outcome
  def outcome(%{"error" => "search_timeout"}), do: "unknown"
  def outcome(%{"error" => "optimizer_failed", "reason" => "optimizer_timeout"}), do: "unknown"
  def outcome(%{"error" => _}), do: "failure"
  # A proposal the validator rejected is a failed attempt, not evidence.
  def outcome(%{"status" => "invalid"}), do: "failure"
  def outcome(_content), do: "complete"

  defp run("search_recipes", args, ctx) do
    emit(ctx, %{"type" => "progress", "step" => "searching_recipes"})

    filters = %{
      query: string_arg(args, "query"),
      slot: string_arg(args, "slot"),
      ingredient: string_arg(args, "ingredient"),
      limit: integer_arg(args, "limit")
    }

    case search(ctx, reject_nil(filters)) do
      {:ok, recipes} ->
        {%{"recipes" => Enum.map(recipes, &recipe_data/1)}, ctx.workspace, :continue}

      {:error, reason} ->
        {%{"error" => reason_string(reason, "search_failed")}, ctx.workspace, :continue}
    end
  end

  defp run("get_recipe", args, ctx) do
    emit(ctx, %{"type" => "progress", "step" => "reading_recipe"})
    id = string_arg(args, "recipe_id")

    case Map.fetch(drafts(ctx), id) do
      {:ok, draft} ->
        {Map.merge(RecipeDraft.to_data(draft), RecipeDraft.outcome(draft)), ctx.workspace,
         :continue}

      :error ->
        case RecipeSearch.get(ctx.household, id) do
          {:ok, recipe} -> {with_nutrition_outcome(recipe), ctx.workspace, :continue}
          {:error, :not_found} -> {%{"error" => "recipe_not_found"}, ctx.workspace, :continue}
          {:error, reason} -> {%{"error" => Atom.to_string(reason)}, ctx.workspace, :continue}
        end
    end
  end

  defp run("create_recipe", args, ctx) do
    emit(ctx, %{"type" => "progress", "step" => "drafting_recipe"})
    drafts = drafts(ctx)

    with true <-
           map_size(drafts) < RecipeDraft.max_drafts() ||
             {:error, %{"error" => "draft_limit_reached"}},
         {:ok, draft} <- RecipeDraft.build(args, ctx.household) do
      data = RecipeDraft.to_data(draft)
      emit(ctx, Map.put(data, "type", "recipe_draft"))
      workspace = Map.put(ctx.workspace, :recipe_drafts, Map.put(drafts, draft.id, draft))

      {data |> Map.put("status", "drafted") |> Map.merge(RecipeDraft.outcome(draft)), workspace,
       :continue}
    else
      {:error, error} -> {error, ctx.workspace, :continue}
    end
  end

  defp run("get_plan", args, ctx) do
    emit(ctx, %{"type" => "progress", "step" => "reading_plan"})

    case MealPlan.parse_range(Map.get(args, "from"), Map.get(args, "to")) do
      {:ok, range} ->
        meals = ctx.account_id |> MealPlan.list(range) |> Enum.map(&planned_meal_data/1)
        {%{"meals" => meals}, ctx.workspace, :continue}

      {:error, :invalid_range} ->
        {%{"error" => "invalid_range"}, ctx.workspace, :continue}
    end
  end

  defp run("reuse_plan", args, ctx) do
    emit(ctx, %{"type" => "progress", "step" => "reading_plan"})

    case MealPlan.reuse(ctx.account_id, Map.get(args, "source_from"), ctx.range, ctx.slots) do
      {:ok, meals} ->
        draft = Enum.map(meals, &Map.take(&1, [:date, :slot, :recipe_id]))

        {%{"status" => "ok", "meals" => Enum.map(meals, &planned_meal_data/1)},
         %{ctx.workspace | draft: draft}, :continue}

      # A failed reuse discards the earlier draft, as a failed optimizer run does.
      {:error, reason} ->
        {%{"error" => Atom.to_string(reason)}, %{ctx.workspace | draft: nil}, :continue}
    end
  end

  defp run("run_optimizer", args, ctx) do
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

      result =
        %{"status" => "ok", "meals" => Enum.map(meals, &meal_data(&1, names))}
        |> with_missing(missing(candidates_by_slot))

      {result, workspace, :continue}
    else
      # Every failed run discards the earlier draft so present_proposal cannot
      # show a plan the agent just asked to change.
      {:error, :no_candidates, slot} ->
        {%{"error" => "no_candidates", "slot" => slot}, %{ctx.workspace | draft: nil}, :continue}

      {:error, reason} ->
        {%{"error" => reason_string(reason, "search_failed")}, %{ctx.workspace | draft: nil},
         :continue}

      {:error, reason, details} ->
        reason = reason_string(reason, "optimizer_error")
        emit(ctx, %{"type" => "optimizer_failed", "reason" => reason})

        {%{"error" => "optimizer_failed", "reason" => reason, "details" => details},
         %{ctx.workspace | draft: nil}, :continue}
    end
  end

  defp run("present_proposal", _args, %{workspace: %{draft: nil}} = ctx),
    do: {%{"error" => "no_plan_to_present"}, ctx.workspace, :continue}

  defp run("present_proposal", _args, ctx) do
    emit(ctx, %{"type" => "progress", "step" => "validating_proposal"})

    case ProposalValidator.validate(ctx.workspace.draft, ctx) do
      {:valid, meals} ->
        {proposal, purchase} = Proposal.build(meals, ctx)
        status = proposal["status"]
        deviations = proposal["deviations"]

        emit(ctx, proposal)

        result = %{
          "status" => status,
          "proposal_id" => proposal["proposal_id"],
          "purchase_total_cents" => purchase.total_cents,
          "purchase_complete" => purchase.complete?,
          "missing_prices" => proposal["purchase"]["missing_prices"],
          "consumed_cost_cents" => purchase.consumed.total_cents,
          "currency" => purchase.currency,
          "budget" => proposal["budget"],
          "deviations" => deviations
        }

        {result, %{ctx.workspace | proposal: proposal}, :continue}

      {:invalid, violations} ->
        {%{"status" => "invalid", "violations" => violations}, ctx.workspace, :continue}
    end
  end

  defp run("get_pantry", _args, ctx) do
    emit(ctx, %{"type" => "progress", "step" => "reading_pantry"})
    pantry = ProjectedPantry.load(ctx.account_id)
    {%{"items" => ProjectedPantry.to_data(pantry)}, ctx.workspace, :continue}
  end

  defp run("lookup_prices", args, ctx) do
    emit(ctx, %{"type" => "progress", "step" => "looking_up_prices"})

    case args |> Map.get("ingredients") |> List.wrap() |> Enum.filter(&is_binary/1) do
      [] ->
        {%{"error" => "ingredients_required"}, ctx.workspace, :continue}

      names ->
        %{prices: prices, missing: missing} =
          names |> Enum.take(@max_price_lookups) |> Prices.lookup_names()

        result = %{
          "prices" => Enum.map(prices, &Prices.offer_data/1),
          "missing" =>
            Enum.map(missing, fn m ->
              %{"ingredient" => m.ingredient, "reason" => Atom.to_string(m.reason)}
            end)
        }

        # Missing prices are named, never zero: the lookup is then partial.
        result = if missing == [], do: result, else: Map.put(result, "outcome", "partial")

        {result, ctx.workspace, :continue}
    end
  end

  defp run("ask_human", args, ctx) do
    case string_arg(args, "question") do
      nil ->
        {%{"error" => "question_required"}, ctx.workspace, :continue}

      question ->
        emit(ctx, %{"type" => "question", "text" => question})
        {%{"status" => "asked"}, ctx.workspace, :end_turn}
    end
  end

  defp run(_name, _arguments, ctx),
    do: {%{"error" => "unknown_tool"}, ctx.workspace, :continue}

  # ---------------------------------------------------------------------------
  # Optimizer
  # ---------------------------------------------------------------------------

  # AI-created Recipe Drafts of the Workspace are candidates for their slots
  # beside the searched recipes; the validator checks them like any recipe.
  defp candidates(ctx, exclude) do
    drafts = ctx |> drafts() |> Map.values() |> Enum.filter(&RecipeDraft.plannable?/1)

    Enum.reduce_while(ctx.slots, {:ok, %{}}, fn slot, {:ok, acc} ->
      filters = %{slot: slot, exclude_recipe_ids: exclude, limit: @optimizer_candidates_per_slot}

      slot_drafts =
        drafts
        |> Enum.filter(&(slot in &1.slots and &1.id not in exclude))
        |> Enum.sort_by(&{&1.name, &1.id})
        |> Enum.map(&draft_candidate/1)

      case search(ctx, filters) do
        {:ok, recipes} ->
          case Enum.map(recipes, &candidate/1) ++ slot_drafts do
            [] -> {:halt, {:error, :no_candidates, slot}}
            candidates -> {:cont, {:ok, Map.put(acc, slot, candidates)}}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp draft_candidate(draft) do
    per_serving = draft.nutrition["per_serving"]

    candidate(%{
      id: draft.id,
      name: draft.name,
      calories_per_serving: per_serving["calories"],
      protein_g_per_serving: per_serving["protein_g"],
      carbs_g_per_serving: per_serving["carbs_g"],
      fat_g_per_serving: per_serving["fat_g"]
    })
  end

  # Candidate costs and the Nutrition Goal enter the optimizer with the
  # package-aware purchase calculation and goal relaxation slices of #93; the
  # tracer bullet keeps bounds wide so only coverage decides feasibility.
  #
  # Missing nutrition data is sent as missing (nil), never as zero, and the
  # plan built from it is reported as partial with what is missing.
  defp candidate(recipe) do
    %{
      "recipe_id" => recipe.id,
      "label" => recipe.name,
      "estimated_cost_cents" => 0,
      "calories_per_serving" => Map.get(recipe, :calories_per_serving),
      "protein_g_per_serving" => Map.get(recipe, :protein_g_per_serving),
      "carbs_g_per_serving" => Map.get(recipe, :carbs_g_per_serving),
      "fat_g_per_serving" => Map.get(recipe, :fat_g_per_serving),
      "inventory_hit_count" => 0
    }
  end

  @nutrition_fields ~w(calories_per_serving protein_g_per_serving carbs_g_per_serving
                       fat_g_per_serving)

  # Candidate costs are not priced yet (purchase slice of #93), so every plan
  # misses its estimated cost and is partial until that slice lands.
  defp missing(candidates_by_slot) do
    candidates = candidates_by_slot |> Map.values() |> List.flatten()

    nutrition =
      Enum.filter(@nutrition_fields, fn field -> Enum.any?(candidates, &is_nil(&1[field])) end)

    ["estimated_cost" | nutrition]
  end

  defp with_missing(result, missing),
    do: Map.merge(result, %{"outcome" => "partial", "missing" => missing})

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

  # The solver is never retried: a timeout is inconclusive, and every other
  # failure is a property of the payload.
  defp solve(ctx, payload) do
    {optimizer, opts} = optimizer(ctx)

    attempt = fn state, call ->
      opts = Keyword.update(opts, :timeout_ms, call.timeout_ms, &min(&1, call.timeout_ms))

      case optimizer.solve(payload, opts) do
        {:ok, result} -> {:ok, result, state}
        {:error, reason, details} -> {:error, {reason, details}, state}
      end
    end

    case CallBounds.run(Map.get(ctx, :bounds), :solver, nil, attempt) do
      {:ok, %{"meals" => meals}, _} when is_list(meals) ->
        parse_meals(meals)

      {:ok, _other, _} ->
        {:error, :invalid_optimizer_response, %{}}

      {:error, {reason, details}, _} ->
        {:error, reason, details}

      {:error, reason, _} when reason in [:timeout, :deadline_exceeded] ->
        {:error, :optimizer_timeout, %{}}
    end
  end

  # Recipe search is a read tool: bounded and retried on transient failure.
  defp search(ctx, filters) do
    {module, opts} = Map.get(ctx, :recipe_search) || {RecipeSearch, []}

    attempt = fn state, _call ->
      case search_with(module, ctx.household, filters, opts) do
        {:ok, recipes} -> {:ok, recipes, state}
        {:error, reason} -> {:error, reason, state}
      end
    end

    case CallBounds.run(Map.get(ctx, :bounds), :read, nil, attempt) do
      {:ok, recipes, _} -> {:ok, recipes}
      {:error, :timeout, _} -> {:error, :search_timeout}
      {:error, reason, _} -> {:error, reason}
    end
  end

  defp search_with(RecipeSearch, household, filters, _opts),
    do: RecipeSearch.search(household, filters)

  defp search_with(module, household, filters, opts), do: module.search(household, filters, opts)

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

  defp drafts(ctx), do: RecipeDraft.in_context(ctx)

  defp with_nutrition_outcome(%{"nutrition" => %{"complete" => true}} = recipe), do: recipe

  defp with_nutrition_outcome(recipe),
    do: Map.merge(recipe, %{"outcome" => "partial", "missing" => ["nutrition"]})

  defp recipe_data(recipe) do
    %{
      "recipe_id" => recipe.id,
      "name" => recipe.name,
      "origin" => Map.get(recipe, :origin),
      "slots" => recipe.slots,
      "ingredients" => recipe.ingredients,
      "calories_per_serving" => recipe.calories_per_serving
    }
  end

  defp planned_meal_data(meal) do
    %{
      "date" => Date.to_iso8601(meal.date),
      "slot" => meal.slot,
      "recipe_id" => meal.recipe_id,
      "name" => meal.name
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

  defp reason_string(reason, _default) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(_reason, default), do: default
end
