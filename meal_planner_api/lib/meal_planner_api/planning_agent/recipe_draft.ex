defmodule MealPlannerApi.PlanningAgent.RecipeDraft do
  @moduledoc """
  Recipe Drafts of the planning agent (spec #93, user stories 36–43, issue
  #104): recipes the agent builds during a Planning Session. A Draft exists
  only in the session's Workspace until a human action saves it.

  Every Draft is grounded in the catalog:

    * Ingredients are matched by exact name (case-insensitive) against the
      catalog; any unknown Ingredient rejects the whole Draft, it is never
      invented
    * nutrition per serving is computed by code from the Ingredients'
      nutrition per 100 g or ml. A nutrient is only reported when every
      Ingredient has it in a weight or volume unit; otherwise it is `nil`
      and the nutrition is labelled partial, naming the Ingredients
      without data
    * cost is the consumed-ingredient cost of
      `MealPlannerApi.PlanningAgent.Purchase` over stored prices; missing
      prices are named and left out of the total, never zero

  A Draft carries its Recipe Origin: `ai_created` (the agent's idea) or
  `user_created` (dictated by a Member). An AI-created Draft that breaks a
  household Restriction is rejected; a dictated one is built as dictated
  and Restriction checks apply wherever it would be planned.

  Saving (`persist/4`) happens only from human actions: confirming a
  Proposal that uses an AI-created Draft, or the Member's explicit save of a
  dictated one. A saved Draft is always a Household Recipe, never a Catalog
  Recipe.
  """

  import Ecto.Query

  alias MealPlannerApi.Persistence.Catalog.{
    Ingredient,
    IngredientTag,
    Recipe,
    RecipeIngredient,
    RecipeStep
  }

  alias MealPlannerApi.Planning.RecipeOrigin
  alias MealPlannerApi.PlanningAgent.{Prices, Purchase}
  alias MealPlannerApi.Repo

  @max_drafts 10
  @max_name_length 120
  @max_servings 50
  @max_ingredients 40
  @max_steps 30
  @max_step_length 1_000
  @max_quantity 100_000
  @known_slots ~w(breakfast lunch snack dinner)
  @units %{"g" => :g, "ml" => :ml, "unit" => :unit}
  @nutrients [
    {"calories", :calories_per_100},
    {"protein_g", :protein_g_per_100},
    {"carbs_g", :carbs_g_per_100},
    {"fat_g", :fat_g_per_100}
  ]

  @type ingredient :: %{
          ingredient_id: Ecto.UUID.t(),
          ingredient: String.t(),
          quantity_milli: pos_integer(),
          unit: :g | :ml | :unit
        }

  @type t :: %{
          id: Ecto.UUID.t(),
          name: String.t(),
          source: :ai_generated | :user_created,
          servings: pos_integer(),
          slots: [String.t()],
          ingredients: [ingredient()],
          steps: [String.t()],
          nutrition: map(),
          cost: map()
        }

  @doc "How many Drafts one Planning Session may hold."
  @spec max_drafts() :: pos_integer()
  def max_drafts, do: @max_drafts

  @doc "The JSON schema of `create_recipe` arguments."
  @spec parameters() :: map()
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "maxLength" => @max_name_length},
        "servings" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_servings},
        "slots" => %{
          "type" => "array",
          "items" => %{"type" => "string", "enum" => @known_slots},
          "minItems" => 1
        },
        "origin" => %{
          "type" => "string",
          "enum" => ["ai_created", "user_created"],
          "description" => "user_created only when a Member dictated this recipe"
        },
        "ingredients" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_ingredients,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "ingredient" => %{"type" => "string", "description" => "Catalog Ingredient name"},
              "quantity" => %{"type" => "number", "exclusiveMinimum" => 0},
              "unit" => %{"type" => "string", "enum" => Map.keys(@units)}
            },
            "required" => ["ingredient", "quantity", "unit"],
            "additionalProperties" => false
          }
        },
        "steps" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_steps,
          "items" => %{"type" => "string", "maxLength" => @max_step_length}
        }
      },
      "required" => ["name", "servings", "slots", "origin", "ingredients", "steps"],
      "additionalProperties" => false
    }
  end

  @doc """
  Builds a Draft from `create_recipe` arguments for the Household context
  `household`. Returns `{:ok, draft}` or `{:error, error}` where `error` is
  the tool error content (`invalid_recipe` with a reason,
  `unknown_ingredients` with their names, or `restriction_conflict`).
  """
  @spec build(map(), map()) :: {:ok, t()} | {:error, map()}
  def build(args, household) do
    with {:ok, name} <- name(args),
         {:ok, servings} <- servings(args),
         {:ok, slots} <- slots(args),
         {:ok, source} <- source(args),
         {:ok, requested} <- requested_ingredients(args),
         {:ok, steps} <- steps(args),
         {:ok, ingredients, catalog} <- resolve(requested),
         :ok <- restriction_check(source, ingredients, household) do
      {:ok,
       %{
         id: Ecto.UUID.generate(),
         name: name,
         source: source,
         servings: servings,
         slots: slots,
         ingredients: ingredients,
         steps: steps,
         nutrition: nutrition(ingredients, catalog, servings),
         cost: cost(ingredients, servings)
       }}
    end
  end

  @doc "The Draft as shown to the agent and the Member."
  @spec to_data(t()) :: map()
  def to_data(draft) do
    %{
      "recipe_id" => draft.id,
      "name" => draft.name,
      "origin" => RecipeOrigin.label(draft.source),
      "draft" => true,
      "servings" => draft.servings,
      "slots" => draft.slots,
      "ingredients" => Enum.map(draft.ingredients, &ingredient_data/1),
      "steps" => draft.steps,
      "nutrition" => draft.nutrition,
      "cost" => draft.cost
    }
  end

  @doc """
  The tool outcome of a Draft: `complete`, or `partial` naming whether
  `nutrition` or `prices` are missing.
  """
  @spec outcome(t()) :: map()
  def outcome(draft) do
    missing =
      [{"nutrition", draft.nutrition["complete"]}, {"prices", draft.cost["complete"]}]
      |> Enum.reject(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    if missing == [],
      do: %{"outcome" => "complete"},
      else: %{"outcome" => "partial", "missing" => missing}
  end

  @doc "Whether the Draft may be planned: only AI-created Drafts are, until saved."
  @spec plannable?(t()) :: boolean()
  def plannable?(draft), do: draft.source == :ai_generated

  @doc """
  Reviewed Ingredient Tags of the Drafts' ingredients, as
  `%{draft_id => %{ingredient_id => MapSet.t(tag)}}`, read now.
  """
  @spec reviewed_tags([t()]) :: %{Ecto.UUID.t() => %{Ecto.UUID.t() => MapSet.t(atom())}}
  def reviewed_tags([]), do: %{}

  def reviewed_tags(drafts) do
    by_ingredient = drafts |> Enum.flat_map(&ingredient_ids/1) |> tags_by_ingredient()

    Map.new(drafts, fn draft ->
      {draft.id, Map.take(by_ingredient, ingredient_ids(draft))}
    end)
  end

  @doc "The catalog Ingredient ids a Draft uses."
  @spec ingredient_ids(t()) :: [Ecto.UUID.t()]
  def ingredient_ids(draft), do: Enum.map(draft.ingredients, & &1.ingredient_id)

  @doc """
  Saves the Draft as a Household Recipe of `account_id` with `source` as its
  Recipe Origin, keeping the Draft's id, through `repo` (inside the caller's
  transaction). Nutrition is stored only where it is complete.
  """
  @spec persist(module(), t(), Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          {:ok, Recipe.t()} | {:error, :invalid_recipe}
  def persist(repo, draft, account_id, user_id) do
    per_serving = draft.nutrition["per_serving"]

    with {:ok, recipe} <-
           %Recipe{id: draft.id}
           |> Recipe.changeset(%{
             account_id: account_id,
             created_by_user_id: user_id,
             name: draft.name,
             servings: draft.servings,
             source: draft.source,
             suitable_for_slots: draft.slots,
             calories_per_serving: per_serving["calories"],
             protein_g_per_serving: decimal(per_serving["protein_g"]),
             carbs_g_per_serving: decimal(per_serving["carbs_g"]),
             fat_g_per_serving: decimal(per_serving["fat_g"])
           })
           |> repo.insert(),
         :ok <- insert_all(repo, draft.ingredients, &ingredient_changeset(recipe, &1)),
         :ok <-
           insert_all(repo, Enum.with_index(draft.steps, 1), fn {text, number} ->
             RecipeStep.changeset(%RecipeStep{}, %{
               recipe_id: recipe.id,
               step_number: number,
               instructions: text
             })
           end) do
      {:ok, recipe}
    else
      {:error, _} -> {:error, :invalid_recipe}
    end
  end

  # ---------------------------------------------------------------------------
  # Argument validation
  # ---------------------------------------------------------------------------

  defp name(args) do
    case Map.get(args, "name") do
      name when is_binary(name) ->
        case String.trim(name) do
          "" ->
            invalid("name_required")

          trimmed ->
            if String.length(trimmed) > @max_name_length,
              do: invalid("name_too_long"),
              else: {:ok, trimmed}
        end

      _ ->
        invalid("name_required")
    end
  end

  defp servings(args) do
    case Map.get(args, "servings") do
      n when is_integer(n) and n >= 1 and n <= @max_servings -> {:ok, n}
      _ -> invalid("invalid_servings")
    end
  end

  defp slots(args) do
    case Map.get(args, "slots") do
      [_ | _] = slots ->
        if Enum.all?(slots, &(&1 in @known_slots)),
          do: {:ok, Enum.uniq(slots)},
          else: invalid("invalid_slots")

      _ ->
        invalid("invalid_slots")
    end
  end

  defp source(args) do
    case RecipeOrigin.draft_source(Map.get(args, "origin", "ai_created")) do
      {:ok, source} -> {:ok, source}
      :error -> invalid("invalid_origin")
    end
  end

  defp requested_ingredients(args) do
    with [_ | _] = items when length(items) <= @max_ingredients <- Map.get(args, "ingredients"),
         {:ok, parsed} <- parse_ingredients(items) do
      keys = Enum.map(parsed, &{String.downcase(&1.name), &1.unit})

      if Enum.uniq(keys) == keys, do: {:ok, parsed}, else: invalid("duplicate_ingredient")
    else
      {:error, _} = error -> error
      _ -> invalid("invalid_ingredient")
    end
  end

  defp parse_ingredients(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case parse_ingredient(item) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, invalid("invalid_ingredient")}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_ingredient(%{"ingredient" => name, "quantity" => quantity, "unit" => unit})
       when is_binary(name) and is_number(quantity) and quantity > 0 and
              quantity <= @max_quantity and is_map_key(@units, unit) do
    case String.trim(name) do
      "" ->
        :error

      trimmed ->
        quantity_milli = round(quantity * 1000)

        if quantity_milli > 0,
          do: {:ok, %{name: trimmed, quantity_milli: quantity_milli, unit: @units[unit]}},
          else: :error
    end
  end

  defp parse_ingredient(_item), do: :error

  defp steps(args) do
    case Map.get(args, "steps") do
      [_ | _] = steps when length(steps) <= @max_steps ->
        trimmed = Enum.map(steps, fn step -> if is_binary(step), do: String.trim(step) end)

        if Enum.all?(
             trimmed,
             &(is_binary(&1) and &1 != "" and String.length(&1) <= @max_step_length)
           ),
           do: {:ok, trimmed},
           else: invalid("invalid_steps")

      _ ->
        invalid("invalid_steps")
    end
  end

  defp invalid(reason), do: {:error, %{"error" => "invalid_recipe", "reason" => reason}}

  # ---------------------------------------------------------------------------
  # Catalog grounding
  # ---------------------------------------------------------------------------

  defp resolve(requested) do
    lowered = requested |> Enum.map(&String.downcase(&1.name)) |> Enum.uniq()

    catalog =
      from(i in Ingredient, where: fragment("lower(?)", i.name) in ^lowered)
      |> Repo.all()
      |> Map.new(&{String.downcase(&1.name), &1})

    case Enum.reject(requested, &Map.has_key?(catalog, String.downcase(&1.name))) do
      [] ->
        ingredients =
          Enum.map(requested, fn item ->
            ingredient = Map.fetch!(catalog, String.downcase(item.name))

            %{
              ingredient_id: ingredient.id,
              ingredient: ingredient.name,
              quantity_milli: item.quantity_milli,
              unit: item.unit
            }
          end)

        {:ok, ingredients, Map.new(catalog, fn {_, i} -> {i.id, i} end)}

      unknown ->
        {:error,
         %{
           "error" => "unknown_ingredients",
           "ingredients" => unknown |> Enum.map(& &1.name) |> Enum.uniq()
         }}
    end
  end

  defp restriction_check(:user_created, _ingredients, _household), do: :ok

  defp restriction_check(_source, ingredients, household) do
    ids = Enum.map(ingredients, & &1.ingredient_id)
    allergic? = Enum.any?(ids, &MapSet.member?(household.allergic_ingredient_ids, &1))

    tagged? =
      ids
      |> tags_by_ingredient()
      |> Map.values()
      |> Enum.any?(&(not MapSet.disjoint?(&1, household.forbidden_tags)))

    if allergic? or tagged?, do: {:error, %{"error" => "restriction_conflict"}}, else: :ok
  end

  defp tags_by_ingredient([]), do: %{}

  defp tags_by_ingredient(ids) do
    from(t in IngredientTag,
      where: t.ingredient_id in ^Enum.uniq(ids) and t.status == :reviewed,
      select: {t.ingredient_id, t.tag}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, tags} -> {id, MapSet.new(tags)} end)
  end

  # ---------------------------------------------------------------------------
  # Nutrition and cost, computed by code
  # ---------------------------------------------------------------------------

  defp nutrition(ingredients, catalog, servings) do
    without_data =
      ingredients
      |> Enum.filter(fn item ->
        item.unit == :unit or
          Enum.any?(@nutrients, fn {_, field} ->
            is_nil(Map.get(catalog[item.ingredient_id], field))
          end)
      end)
      |> Enum.map(& &1.ingredient)

    per_serving =
      Map.new(@nutrients, fn {key, field} ->
        {key, nutrient_per_serving(key, field, ingredients, catalog, servings)}
      end)

    %{"per_serving" => per_serving, "complete" => without_data == [], "missing" => without_data}
  end

  # A nutrient is reported only when every ingredient contributes a known
  # amount; a partial sum would read as a complete value.
  defp nutrient_per_serving(key, field, ingredients, catalog, servings) do
    amounts =
      Enum.map(ingredients, fn item ->
        per_100 = Map.get(catalog[item.ingredient_id], field)

        if item.unit != :unit and not is_nil(per_100) do
          # quantity_milli / 1000 units of 100 → quantity_milli / 100_000.
          Decimal.mult(Decimal.new(per_100), Decimal.div(item.quantity_milli, 100_000))
        end
      end)

    if Enum.any?(amounts, &is_nil/1) do
      nil
    else
      total = amounts |> Enum.reduce(Decimal.new(0), &Decimal.add/2) |> Decimal.div(servings)

      if key == "calories",
        do: total |> Decimal.round(0) |> Decimal.to_integer(),
        else: total |> Decimal.round(1) |> Decimal.to_float()
    end
  end

  defp cost(ingredients, servings) do
    needs =
      Enum.reduce(ingredients, %{}, fn item, acc ->
        Map.update(
          acc,
          {item.ingredient_id, item.unit},
          item.quantity_milli,
          &(&1 + item.quantity_milli)
        )
      end)

    ids = Enum.map(ingredients, & &1.ingredient_id)
    names = Map.new(ingredients, &{&1.ingredient_id, &1.ingredient})
    purchase = Purchase.calculate(needs, %{}, Prices.offers_for(ids), names)
    data = Purchase.consumed_data(purchase)
    total = data["total_cents"]

    Map.put(data, "per_serving_cents", div(2 * total + servings, 2 * servings))
  end

  # ---------------------------------------------------------------------------

  defp ingredient_data(item) do
    %{
      "ingredient" => item.ingredient,
      "quantity_milli" => item.quantity_milli,
      "unit" => Atom.to_string(item.unit)
    }
  end

  defp ingredient_changeset(recipe, item) do
    RecipeIngredient.changeset(%RecipeIngredient{}, %{
      recipe_id: recipe.id,
      ingredient_id: item.ingredient_id,
      quantity_milli: item.quantity_milli,
      unit: item.unit
    })
  end

  defp insert_all(repo, items, changeset_fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case repo.insert(changeset_fun.(item)) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp decimal(nil), do: nil
  defp decimal(value), do: Decimal.from_float(value * 1.0)
end
