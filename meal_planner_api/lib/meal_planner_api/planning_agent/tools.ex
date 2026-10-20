defmodule MealPlannerApi.PlanningAgent.Tools do
  @moduledoc """
  Agent-callable tool catalog of the planning agent (spec #93). No tool writes
  household data (`lookup_prices` records the Price Observations a live
  lookup returns), and no tool grants a Deviation Approval or an Absence
  Exception: those are human-only actions of `MealPlannerApi.PlanningAgent.Session`.

    * `search_recipes` — structured search; Restriction-violating recipes are
      excluded by code
    * `get_workspace` — the current Workspace: Proposal, draft, Pins,
      Excluded Recipes, Released Meals and variety cap
    * `edit_workspace` — Pin, unpin, exclude, include, release meals, set
      the variety cap and set a meal's guests (`MealPlannerApi.PlanningAgent.Diners`);
      invalid edits are refused with a reason and approvals can never be set
    * `get_plan` — the Household's Planned Meals by date or range (planned,
      not eaten)
    * `reuse_plan` — a past stretch of the Meal Plan as the new draft; it
      must pass `present_proposal` like any optimizer plan
    * `run_optimizer` — the existing optimizer over Restriction-safe
      candidates; it keeps every Pin and, once a Proposal exists, every meal
      that was not released. Failures are typed errors, never a fallback plan
    * `get_pantry` — the Projected Pantry (Pantry minus stock committed to
      not-yet-cooked Planned Meals)
    * `lookup_prices` — prices with provenance and age, read from the
      database first and refreshed live through the scraper when missing or
      24 hours old or older; missing prices are reported, never invented,
      and a failed refresh keeps the old price with its real age
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
    * `set_session_brand` — sets or clears the Session Brand of an
      ingredient in the Workspace (never household settings); every change
      is shown to the Member as a `session_brand_changed` event
    * `ask_human` — one question; ends the turn

  Brands steer the Purchase softly: a Session Brand, else the Household's
  Brand Preference, is bought when it can be; when it cannot, the Proposal
  lists the substitution, and when the Purchase breaks the budget the
  result lists cheaper brand alternatives with their price difference for
  the agent to offer. Code never swaps a chosen brand on its own.

  Read calls (recipe search, live price lookups) and solver calls run within
  `MealPlannerApi.PlanningAgent.CallBounds`: their own deadline and retry
  budget, clipped by the turn's global deadline.

  Every call runs with the session's tool context. The Household always comes
  from that context: tool schemas carry no Household and any Household named
  in model arguments is ignored. Unknown tools are rejected by code.
  """

  alias MealPlannerApi.Optimization.Variety

  alias MealPlannerApi.PlanningAgent.{
    CallBounds,
    Diners,
    IngredientMatch,
    MealPlan,
    Prices,
    PriceScraper,
    ProjectedPantry,
    Proposal,
    ProposalValidator,
    Purchase,
    RecipeDraft,
    RecipeSearch,
    Workspace
  }

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
  # Matches `Prices.max_ingredients/0`: the lookup flags any names past it.
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
            "set_guests: the guests of one date and slot as the household states them (e.g. " <>
            "\"6 friends Tuesday lunch\"); every meal is scaled to its diners by code, guests " <>
            "included, so never refuse a meal for its size. guests 0 clears them. Add " <>
            "guest_restrictions only when the household says a guest has an allergy or diet; " <>
            "never ask whether guests have any. " <>
            "Approvals and confirmations are never possible here. Refused edits return a reason.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" =>
                ~w(pin unpin exclude include release release_all set_variety_cap set_guests)
            },
            "date" => %{"type" => "string", "description" => "ISO date inside the range"},
            "slot" => %{"type" => "string"},
            "recipe_id" => %{"type" => "string"},
            "variety_cap" => %{"type" => "integer", "minimum" => 1},
            "guests" => %{
              "type" => "integer",
              "minimum" => 0,
              "maximum" => Diners.max_guests(),
              "description" => "Guests at that meal, besides the household"
            },
            "guest_restrictions" => %{
              "type" => "array",
              "items" => %{"type" => "string", "enum" => Diners.restriction_names()},
              "description" =>
                "Only the allergies or diets the household volunteered for its guests"
            }
          },
          "required" => ["action"],
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
            "Ingredients reject the Draft and list close catalog matches to use instead; one " <>
            "under missing_from_catalog has none, so never retry it under another name. " <>
            "Nutrition and cost are computed by code and reported partial when data is " <>
            "missing; a partial Draft is usable, never re-create it only for that. To fix a " <>
            "Draft, call again with replaces_recipe_id (the same name and origin also " <>
            "revise it): it never adds a duplicate. The Draft lives only in this chat; it is " <>
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
            "Pins and every meal of the last Proposal that was not released stay fixed; a " <>
            "meal released with release always gets a different recipe. Optionally exclude " <>
            "more recipes for this run: they never replace a fixed meal, only the meals the " <>
            "run may change. Returns the plan with its Deviations or a typed error.",
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
          "Read prices of the Products covering the named ingredients, with product, " <>
            "presentation, supermarket, currency, observation date and age. Missing or stale " <>
            "prices are refreshed live; when that fails the old price keeps its real age and a " <>
            "warning is returned. Ingredient names match the catalog by similarity; an unknown " <>
            "name is listed as missing with its close_matches to retry with. Ingredients " <>
            "without a price are listed as missing; never " <>
            "assume a price for them, and tell the household when a price is stale. The " <>
            "ingredients are required; brand and product only narrow their offers, together, " <>
            "and a missing entry names every filter asked. When `truncated` is true, some " <>
            "ingredients or offers were left out; the warnings say which.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "ingredients" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "minItems" => 1,
              "maxItems" => @max_price_lookups,
              "description" => "Ingredient names, as returned by search_recipes"
            },
            "brand" => %{
              "type" => "string",
              "description" =>
                "Only the named ingredients' Products of this brand, e.g. to answer how " <>
                  "much a brand costs; looked up live when no stored Product has it"
            },
            "product" => %{
              "type" => "string",
              "description" =>
                "Only the named ingredients' Products whose name contains this text"
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
        name: "set_session_brand",
        description:
          "Set the brand to buy for one ingredient in this Planning Session only (a Session " <>
            "Brand), or clear it with brand null. It overrides the household's Brand " <>
            "Preference for this session and never changes household settings. The brand " <>
            "must be one a stored Product of the ingredient has (use lookup_prices with brand " <>
            "first). An unknown ingredient returns close_matches to retry with. The household " <>
            "sees every change. Only set it when the household asks.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "ingredient" => %{"type" => "string", "description" => "Ingredient name"},
            "brand" => %{
              "type" => ["string", "null"],
              "description" => "Brand to buy; null clears the Session Brand"
            }
          },
          "required" => ["ingredient", "brand"],
          "additionalProperties" => false
        }
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

  defp run("get_workspace", _args, ctx),
    do: {Workspace.to_data(ctx.workspace, ctx), ctx.workspace, :continue}

  defp run("edit_workspace", args, ctx) do
    case Workspace.edit(ctx.workspace, args, ctx) do
      {:ok, workspace, result} ->
        {result, workspace, :continue}

      {:error, code, extra} ->
        {Map.merge(%{"error" => code, "reason" => Workspace.reason(code)}, extra), ctx.workspace,
         :continue}
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

    with {:ok, replaced} <- replaced_draft(args, drafts),
         {:ok, built} <- RecipeDraft.build(args, ctx.household),
         draft = RecipeDraft.revision(built, replaced || RecipeDraft.same_recipe(drafts, built)),
         revised? = Map.has_key?(drafts, draft.id),
         true <-
           (revised? or map_size(drafts) < RecipeDraft.max_drafts()) ||
             {:error, %{"error" => "draft_limit_reached"}},
         :ok <- not_escaping_budget(draft, ctx.workspace) do
      data = RecipeDraft.to_data(draft)
      emit(ctx, Map.put(data, "type", "recipe_draft"))

      workspace =
        ctx.workspace
        |> Map.put(:recipe_drafts, Map.put(drafts, draft.id, draft))
        |> Workspace.rename_pins(draft.id, draft.name)

      {data
       |> Map.put("status", if(revised?, do: "revised", else: "drafted"))
       |> with_renamed(Map.get(draft, :renamed, []))
       |> Map.merge(RecipeDraft.outcome(draft)), workspace, :continue}
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
      args
      |> Map.get("exclude_recipe_ids", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.concat(MapSet.to_list(ctx.workspace.excluded))
      |> Enum.uniq()

    fixed = Workspace.fixed_meals(ctx.workspace)
    {exclude_everywhere, avoided} = avoided_meals(ctx, exclude, fixed)

    with {:ok, candidates_by_slot} <- candidates(ctx, exclude),
         {:ok, candidates_by_slot} <- with_fixed_candidates(ctx, candidates_by_slot, fixed),
         avoided = Enum.uniq(avoided ++ guest_avoided(ctx, candidates_by_slot, fixed)),
         {:ok, payload} <- payload(ctx, candidates_by_slot, exclude_everywhere, fixed, avoided),
         {:ok, solution} <- solve(ctx, payload),
         :ok <- keeps_fixed(solution.meals, fixed),
         :ok <- changes_avoided(solution.meals, avoided) do
      names =
        candidates_by_slot
        |> Map.values()
        |> List.flatten()
        |> Map.new(&{&1["recipe_id"], &1["label"]})

      workspace = %{ctx.workspace | draft: solution.meals}

      result =
        %{"status" => "ok", "meals" => Enum.map(solution.meals, &meal_data(&1, names))}
        |> Map.merge(solution.extra)
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

      {:error, :fixed_meal_unavailable, meal} ->
        {%{"error" => "fixed_meal_unavailable", "meal" => meal}, %{ctx.workspace | draft: nil},
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

    # Approved Absence Exceptions of the Workspace are validator input.
    exceptions = Map.get(ctx.workspace, :absence_exceptions, [])

    case ProposalValidator.validate(
           ctx.workspace.draft,
           Map.put(ctx, :absence_exceptions, exceptions)
         ) do
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
          "deviations" => deviations,
          "brand_substitutions" => proposal["purchase"]["brand_substitutions"],
          # A budget conflict is answered with the cheaper brand options and
          # their price difference; the agent offers them, never applies them.
          "brand_alternatives" =>
            if(deviations == [], do: [], else: Purchase.brand_alternatives(purchase))
        }

        conflict = budget_conflict(deviations, purchase, ctx.household.budget_cents)
        result = if conflict, do: Map.put(result, "budget_conflict", conflict), else: result

        workspace =
          ctx.workspace
          |> Workspace.present(proposal, meals)
          |> Map.put(:budget_conflict, conflict)

        {result, workspace, :continue}

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

    names =
      args
      |> Map.get("ingredients")
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))

    case names do
      [] ->
        # Brand and Product only narrow named Ingredients; there is no
        # catalog-wide price search.
        {%{
           "error" => "ingredients_required",
           "reason" => "Pass the ingredient names; brand and product only narrow their offers."
         }, ctx.workspace, :continue}

      names ->
        %{
          prices: prices,
          missing: missing,
          warnings: warnings,
          truncated: truncated,
          refresh_memo: memo
        } =
          Prices.lookup(names,
            now: now(ctx),
            refresh: &scrape(ctx, &1),
            refresh_memo: Map.get(ctx.workspace, :price_refreshes, %{}),
            brand: trimmed_arg(args, "brand"),
            product: trimmed_arg(args, "product")
          )

        result = %{
          "prices" => Enum.map(prices, &Prices.offer_data/1),
          "missing" => Enum.map(missing, &Prices.missing_data/1),
          "warnings" => Enum.map(warnings, &Prices.warning_data/1),
          "truncated" => truncated
        }

        # Missing prices are named, never zero, and stale or unrefreshed
        # prices are flagged: the lookup is then partial.
        result =
          if missing == [] and warnings == [],
            do: result,
            else: Map.put(result, "outcome", "partial")

        # Recent refreshes are kept in the Workspace, which the Session
        # checkpoints after every tool call, so the session does not scrape
        # the same Ingredient again on every lookup.
        {result, Map.put(ctx.workspace, :price_refreshes, memo), :continue}
    end
  end

  defp run("set_session_brand", args, ctx) do
    with {:ok, name} <- required_string(args, "ingredient", "ingredient_required"),
         {:ok, ingredient} <- find_ingredient(name),
         {:ok, brand} <- requested_brand(args, ingredient) do
      before = effective_brand(ctx, ingredient.id)
      # A Workspace restored from an older snapshot may lack the field.
      session_brands = Map.get(ctx.workspace, :session_brands, %{})

      session_brands =
        case brand do
          nil ->
            Map.delete(session_brands, ingredient.id)

          brand ->
            Map.put(session_brands, ingredient.id, %{ingredient: ingredient.name, brand: brand})
        end

      workspace = Map.put(ctx.workspace, :session_brands, session_brands)
      now = effective_brand(%{ctx | workspace: workspace}, ingredient.id)

      # Checkpointed before the Member is told, so the session keeps the
      # change even when this turn is cut by the deadline right after.
      report_workspace(ctx, workspace)

      emit(ctx, %{
        "type" => "session_brand_changed",
        "ingredient" => ingredient.name,
        "brand" => brand_name(now),
        "source" => brand_source(now),
        "previous_brand" => brand_name(before),
        "previous_source" => brand_source(before)
      })

      {%{
         "status" => "ok",
         "ingredient" => ingredient.name,
         "brand" => brand_name(now),
         "source" => brand_source(now),
         "previous_brand" => brand_name(before)
       }, workspace, :continue}
    else
      {:error, reason} -> {%{"error" => reason}, ctx.workspace, :continue}
      {:error, reason, extra} -> {Map.put(extra, "error", reason), ctx.workspace, :continue}
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
  # Infeasible budget (issue #148)
  # ---------------------------------------------------------------------------

  @budget_guidance "This Proposal breaks the budget. Try other existing recipes first " <>
                     "(exclude the expensive ones and run the optimizer again). If no plan " <>
                     "fits, tell the household it cannot be done within the budget, name the " <>
                     "real cause (packages_over_budget lists every package that alone costs " <>
                     "more than the whole budget) and ask with ask_human whether they want " <>
                     "new recipes created. Never create recipes before they say yes."

  # A budget Deviation is answered with its real cause and the guidance the
  # agent must relay; nil when the Purchase fits the budget.
  defp budget_conflict(deviations, purchase, budget_cents) do
    case Enum.find(deviations, &(&1["type"] == "budget")) do
      nil ->
        nil

      deviation ->
        %{
          "budget_cents" => budget_cents,
          "purchase_total_cents" => purchase.total_cents,
          "over_by_cents" => deviation["difference_cents"],
          "packages_over_budget" =>
            for line <- purchase.lines, line.offer.price_cents > budget_cents do
              %{
                "ingredient" => line.offer.ingredient,
                "product" => line.offer.product,
                "package_price_cents" => line.offer.price_cents
              }
            end,
          "guidance" => @budget_guidance
        }
    end
  end

  # An AI-created Recipe Draft never escapes a budget Deviation the household
  # has not answered yet: until their next message, only a recipe a Member
  # dictates is built.
  defp not_escaping_budget(draft, workspace) do
    if RecipeDraft.plannable?(draft) and Map.get(workspace, :budget_conflict) != nil do
      {:error,
       %{
         "error" => "new_recipes_not_requested",
         "reason" =>
           "The household has not asked for new recipes. Tell them the plan cannot fit the " <>
             "budget with the existing recipes, name the cause and ask with ask_human " <>
             "whether they want new recipes created."
       }}
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Brands
  # ---------------------------------------------------------------------------

  defp effective_brand(ctx, ingredient_id),
    do: Map.get(Proposal.brand_choices(ctx), ingredient_id)

  defp brand_name(nil), do: nil
  defp brand_name(%{brand: brand}), do: brand
  defp brand_source(nil), do: nil
  defp brand_source(%{source: source}), do: Atom.to_string(source)

  defp required_string(args, key, error) do
    case trimmed_arg(args, key) do
      nil -> {:error, error}
      value -> {:ok, value}
    end
  end

  # An unknown name lists its close catalog matches (issue #160).
  defp find_ingredient(name) do
    case Prices.ingredient_by_name(name) do
      nil ->
        {:error, "unknown_ingredient",
         %{"close_matches" => Map.fetch!(IngredientMatch.close_matches([name]), name)}}

      ingredient ->
        {:ok, ingredient}
    end
  end

  # nil clears the Session Brand; any other brand must be one a stored
  # Product of the ingredient has, spelled as stored.
  defp requested_brand(args, ingredient) do
    case Map.fetch(args, "brand") do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, brand} when is_binary(brand) ->
        case String.trim(brand) do
          "" ->
            {:error, "brand_required"}

          brand ->
            case Prices.stored_brand(ingredient.id, brand) do
              nil -> {:error, "unknown_brand"}
              stored -> {:ok, stored}
            end
        end

      _ ->
        {:error, "brand_required"}
    end
  end

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

  # A fixed meal's recipe may fall outside the searched candidates of its
  # slot; it is added so the optimizer can keep it. A recipe that now violates
  # a Restriction is flagged, so the optimizer refuses it instead of keeping it.
  # A fixed meal of an AI-created Recipe Draft of the Workspace is kept from
  # the Draft itself, since Drafts are not stored recipes.
  defp with_fixed_candidates(_ctx, candidates_by_slot, []), do: {:ok, candidates_by_slot}

  defp with_fixed_candidates(ctx, candidates_by_slot, fixed) do
    drafts = ctx |> drafts() |> Map.filter(fn {_id, draft} -> RecipeDraft.plannable?(draft) end)
    {draft_meals, stored_meals} = Enum.split_with(fixed, &Map.has_key?(drafts, &1.recipe_id))

    candidates_by_slot =
      Enum.reduce(draft_meals, candidates_by_slot, fn meal, acc ->
        put_draft_candidate(acc, meal.slot, Map.fetch!(drafts, meal.recipe_id))
      end)

    with_stored_fixed(ctx, candidates_by_slot, stored_meals)
  end

  defp with_stored_fixed(_ctx, candidates_by_slot, []), do: {:ok, candidates_by_slot}

  defp with_stored_fixed(ctx, candidates_by_slot, fixed) do
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

  defp put_draft_candidate(candidates_by_slot, slot, draft) do
    candidates = Map.get(candidates_by_slot, slot, [])

    if Enum.any?(candidates, &(&1["recipe_id"] == draft.id)),
      do: candidates_by_slot,
      else: Map.put(candidates_by_slot, slot, candidates ++ [draft_candidate(draft)])
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

  # A Released Meal the household asked to change avoids its previous recipe
  # (issue #148). A recipe excluded for this run that a fixed meal keeps is
  # not excluded everywhere, which would make the fixed meal infeasible: it is
  # avoided on every meal the run may change instead.
  defp avoided_meals(ctx, exclude, fixed) do
    fixed_keys = MapSet.new(fixed, &{&1.date, &1.slot})
    kept_recipes = MapSet.new(fixed, & &1.recipe_id)
    {kept_excluded, exclude_everywhere} = Enum.split_with(exclude, &(&1 in kept_recipes))
    {from_date, to_date} = ctx.range

    free_keys =
      for date <- Date.range(from_date, to_date),
          slot <- ctx.slots,
          not MapSet.member?(fixed_keys, {date, slot}),
          do: {date, slot}

    run_avoided =
      for {date, slot} <- free_keys, recipe_id <- kept_excluded do
        %{date: date, slot: slot, recipe_id: recipe_id}
      end

    avoided =
      (Workspace.avoided_meals(ctx.workspace) ++ run_avoided)
      |> Enum.uniq()
      |> Enum.sort_by(&{Date.to_iso8601(&1.date), &1.slot, &1.recipe_id})

    {exclude_everywhere, avoided}
  end

  # A guest restriction binds its meal only (issue #152): every candidate it
  # forbids is avoided at that day and slot, through the same contract as a
  # Released Meal's previous recipe. Fixed meals stay; the validator checks them.
  defp guest_avoided(ctx, candidates_by_slot, fixed) do
    fixed_keys = MapSet.new(fixed, &{&1.date, &1.slot})

    meals =
      for {{date, slot} = key, %{restrictions: [_ | _]}} <- Diners.guests(ctx),
          not MapSet.member?(fixed_keys, key),
          candidate <- Map.get(candidates_by_slot, slot, []),
          do: %{date: date, slot: slot, recipe_id: candidate["recipe_id"]}

    meals
    |> Diners.conflicts(ctx)
    |> Enum.sort_by(&{Date.to_iso8601(&1.date), &1.slot, &1.recipe_id})
  end

  defp payload(ctx, candidates_by_slot, exclude, fixed, avoided) do
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
      "fixed_meals" => Enum.map(fixed, &meal_key_data/1),
      "avoided_meals" => Enum.map(avoided, &meal_key_data/1)
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

  # Code also guarantees that a Released Meal the household asked to change
  # does not come back with the recipe it had.
  defp changes_avoided(meals, avoided) do
    planned = MapSet.new(meals, &{&1.date, &1.slot, &1.recipe_id})

    if Enum.any?(avoided, &MapSet.member?(planned, {&1.date, &1.slot, &1.recipe_id})),
      do: {:error, :released_meal_unchanged, %{}},
      else: :ok
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
      {:ok, %{"meals" => meals} = result, _} when is_list(meals) ->
        with {:ok, parsed} <- parse_meals(meals) do
          {:ok, %{meals: parsed, extra: Map.take(result, ["deviations", "optimality"])}}
        end

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

  # A live scraper lookup is a read call: bounded and retried on transient
  # failure. It is not a model call, so it uses no iteration or spend.
  defp scrape(ctx, query) do
    {module, opts} = Map.get(ctx, :price_scraper) || {PriceScraper.Unavailable, []}

    attempt = fn state, call ->
      opts = Keyword.put(opts, :receive_timeout, call.timeout_ms)

      case module.fetch(query, opts) do
        {:ok, items} -> {:ok, items, state}
        {:error, reason} -> {:error, reason, state}
      end
    end

    case CallBounds.run(Map.get(ctx, :bounds), :read, nil, attempt) do
      {:ok, items, _} -> {:ok, items}
      {:error, :timeout, _} -> {:error, :scraper_timeout}
      {:error, reason, _} -> {:error, reason}
    end
  end

  defp now(ctx) do
    case Map.get(ctx, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _ -> DateTime.utc_now()
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

  # `replaces_recipe_id` names the Draft of this Workspace that a
  # create_recipe call revises (issue #154).
  defp replaced_draft(args, drafts) do
    case Map.get(args, "replaces_recipe_id") do
      nil ->
        {:ok, nil}

      id ->
        case Map.fetch(drafts, id) do
          {:ok, draft} -> {:ok, draft}
          :error -> {:error, %{"error" => "draft_not_found"}}
        end
    end
  end

  defp drafts(ctx), do: RecipeDraft.in_context(ctx)

  # Requested Ingredient names the catalog spells otherwise (issue #160): the
  # agent is told which catalog name was used, to say it that way.
  defp with_renamed(result, []), do: result

  defp with_renamed(result, renamed) do
    Map.merge(result, %{
      "renamed_ingredients" => renamed,
      "renamed_note" =>
        "These Ingredients were matched to the catalog names shown; call them by those names."
    })
  end

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

  defp meal_key_data(meal),
    do: %{"day" => Date.to_iso8601(meal.date), "slot" => meal.slot, "recipe_id" => meal.recipe_id}

  defp string_arg(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp trimmed_arg(args, key) do
    case string_arg(args, key) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: value
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

  defp report_workspace(%{report_workspace: report}, workspace) when is_function(report, 1),
    do: report.(workspace)

  defp report_workspace(_ctx, _workspace), do: :ok

  defp reason_string(reason, _default) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(_reason, default), do: default
end
