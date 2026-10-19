defmodule MealPlannerApi.PlanningAgent.Battery.Kitchen do
  @moduledoc """
  Builds the fictitious fixtures of one battery task (issue #109): a
  Household with its Members, Restrictions, budget, catalog Ingredients,
  recipes, Products with Price Observations, Pantry lots and pending
  Planned Meals. Every name is invented and fixed, so every run of a task
  sees identical data; the battery builds them inside a database sandbox
  that is rolled back after the run.

  ## Spec

      %{
        range: {first_date, last_date},
        slots: ["lunch", "dinner"],
        budget_cents: pos_integer(),
        members: [%{key: atom(), diet: atom() | nil, allergies: [ingredient_key]}],
        ingredients: [%{key: atom(), name: String.t(), tags: [atom()]}],
        products: [%{ingredient: key, name: String.t(), brand: String.t() | nil,
                     package: {quantity_milli, unit}, price_cents: integer(),
                     observed_at: DateTime.t()}],
        recipes: [%{key: atom(), name: String.t(), ingredients: [key | {key, {milli, unit}}],
                    description: String.t() | nil}],
        pantry: [%{ingredient: key, quantity_milli: integer(), unit: atom()}],
        planned_meals: [%{date: Date.t(), slot: String.t(), recipe: key}]
      }

  The first Member is the Household's Owner and runs the Planning Session.

  The Restrictions that forbid a recipe are computed here from the spec and
  the glossary (`CONTEXT.md`, "Ingredient Tag"), independently of the
  session's own validator, so the grader can check the agent against them.
  """

  import Ecto.Query, only: [from: 2]

  alias MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Persistence.Accounts.{
    Account,
    AccountMembership,
    User,
    UserDietaryProfile,
    UserExcludedIngredient
  }

  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Catalog.Recipe
  alias MealPlannerApi.Persistence.Inventory.InventoryItem
  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.Persistence.Shopping.{PriceObservation, Product, ShoppingItem, Supermarket}
  alias MealPlannerApi.PlanningAgent.Consent
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Subscriptions.Plan

  @supermarket "Battery Market"
  @plan %{name: "family_4", max_users: 4, max_planning_days: 7, revenuecat_entitlement_id: nil}

  # The glossary's diets as forbidden Ingredient Tags ("Ingredient Tag").
  @diet_forbidden %{
    vegetarian: [:contains_meat, :contains_fish],
    pescatarian: [:contains_meat],
    vegan: [:animal_product, :contains_meat, :contains_fish],
    celiac: [:contains_gluten],
    omnivore: []
  }

  @type t :: %{
          account_id: Ecto.UUID.t(),
          owner: %{user_id: Ecto.UUID.t(), membership_id: Ecto.UUID.t(), role: :owner},
          range: {Date.t(), Date.t()},
          slots: [String.t()],
          ingredient_ids: %{atom() => Ecto.UUID.t()},
          ingredient_names: %{atom() => String.t()},
          recipe_ids: %{atom() => Ecto.UUID.t()},
          recipe_ingredients: %{Ecto.UUID.t() => [atom()]},
          forbidden_recipe_ids: MapSet.t(),
          planned_meal_count: non_neg_integer()
        }

  @doc "Builds the fixtures of `spec` and returns what the run and the grader need."
  @spec build(map()) :: t()
  def build(spec) do
    ensure_plan!()
    [owner_spec | other_specs] = spec.members

    owner_user =
      FactoryHelpers.user_with_memberships(
        %{email: "battery-owner@example.test", name: "Battery Owner"},
        [{%{plan: :family_4, name: "Battery Household"}, :owner}]
      )

    [membership] = owner_user.memberships
    account_id = membership.account_id
    budget!(account_id, spec.budget_cents)

    ingredients = Map.new(spec.ingredients, &{&1.key, ingredient!(&1)})
    ids = Map.new(ingredients, fn {key, ingredient} -> {key, ingredient.id} end)

    others =
      other_specs
      |> Enum.with_index(1)
      |> Enum.map(fn {member, index} -> {member, member!(account_id, index)} end)

    members = [{owner_spec, owner_user.id} | others]

    Enum.each(members, fn {member, user_id} -> restrictions!(member, user_id, ids) end)
    :ok = Consent.record(account_id, owner_user.id)

    Enum.each(spec.products, &product!(&1, ids))
    recipes = Map.new(spec.recipes, &{&1.key, recipe!(&1, ids, spec.slots)})
    Enum.each(spec[:pantry] || [], &pantry!(&1, account_id, ids))

    Enum.each(spec[:planned_meals] || [], fn meal ->
      planned_meal!(account_id, meal, Map.fetch!(recipes, meal.recipe))
    end)

    recipe_ingredients =
      Map.new(spec.recipes, fn recipe ->
        {Map.fetch!(recipes, recipe.key).id, Enum.map(recipe.ingredients, &ingredient_key/1)}
      end)

    %{
      account_id: account_id,
      owner: %{user_id: owner_user.id, membership_id: membership.id, role: :owner},
      range: spec.range,
      slots: spec.slots,
      ingredient_ids: ids,
      ingredient_names: Map.new(spec.ingredients, &{&1.key, &1.name}),
      recipe_ids: Map.new(recipes, fn {key, recipe} -> {key, recipe.id} end),
      recipe_ingredients: recipe_ingredients,
      forbidden_recipe_ids: forbidden_recipe_ids(spec, recipes),
      planned_meal_count: length(spec[:planned_meals] || [])
    }
  end

  @doc """
  What a run left saved for the Household beyond the fixtures: Planned
  Meals, Shopping List lines and Household Recipes.
  """
  @spec saved(t()) :: %{
          planned_meals: non_neg_integer(),
          shopping_lines: non_neg_integer(),
          household_recipes: non_neg_integer()
        }
  def saved(%{account_id: account_id} = kitchen) do
    count = fn query -> Repo.aggregate(query, :count) end

    %{
      planned_meals:
        count.(from(m in ScheduledMeal, where: m.account_id == ^account_id)) -
          kitchen.planned_meal_count,
      shopping_lines: count.(from(i in ShoppingItem, where: i.account_id == ^account_id)),
      household_recipes: count.(from(r in Recipe, where: r.account_id == ^account_id))
    }
  end

  @doc "Whether the catalog holds any recipe, so fixtures would not be the only recipes."
  @spec catalog_empty?() :: boolean()
  def catalog_empty?, do: not Repo.exists?(from(r in Recipe, select: 1))

  @doc """
  A description of the fixtures of `spec` without generated ids, for
  checking that the fixtures are reproducible.
  """
  @spec describe(map()) :: map()
  def describe(spec) do
    names = Map.new(spec.ingredients, &{&1.key, &1.name})

    %{
      range: spec.range,
      slots: spec.slots,
      budget_cents: spec.budget_cents,
      members: Enum.map(spec.members, &Map.take(&1, [:diet, :allergies])),
      recipes:
        Enum.map(spec.recipes, fn recipe ->
          {recipe.name, Enum.map(recipe.ingredients, &Map.fetch!(names, ingredient_key(&1)))}
        end),
      products:
        Enum.map(spec.products, fn product ->
          {Map.fetch!(names, product.ingredient), product.name, product.price_cents,
           product.package, product.observed_at}
        end),
      pantry: spec[:pantry] || [],
      planned_meals: spec[:planned_meals] || []
    }
  end

  # ---------------------------------------------------------------------------
  # Ground truth
  # ---------------------------------------------------------------------------

  defp forbidden_recipe_ids(spec, recipes) do
    tags = Map.new(spec.ingredients, &{&1.key, MapSet.new(&1.tags)})

    forbidden_tags =
      spec.members
      |> Enum.flat_map(fn member -> Map.get(@diet_forbidden, member[:diet], []) end)
      |> MapSet.new()

    # An allergy forbids its Ingredient and every Ingredient sharing one of
    # its allergen tags.
    allergy_tags =
      spec.members
      |> Enum.flat_map(&(&1[:allergies] || []))
      |> Enum.flat_map(&MapSet.to_list(Map.fetch!(tags, &1)))
      |> MapSet.new()

    allergies = spec.members |> Enum.flat_map(&(&1[:allergies] || [])) |> MapSet.new()
    blocked = MapSet.union(forbidden_tags, allergy_tags)

    forbidden? = fn key ->
      MapSet.member?(allergies, key) or not MapSet.disjoint?(Map.fetch!(tags, key), blocked)
    end

    for recipe <- spec.recipes,
        Enum.any?(recipe.ingredients, &forbidden?.(ingredient_key(&1))),
        into: MapSet.new(),
        do: Map.fetch!(recipes, recipe.key).id
  end

  defp ingredient_key({key, _quantity}), do: key
  defp ingredient_key(key), do: key

  # ---------------------------------------------------------------------------
  # Builders
  # ---------------------------------------------------------------------------

  defp ensure_plan! do
    %Plan{}
    |> Plan.changeset(@plan)
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:name])
  end

  defp budget!(account_id, cents) do
    Account
    |> Repo.get!(account_id)
    |> Ecto.Changeset.change(default_budget_cents: cents)
    |> Repo.update!()
  end

  defp member!(account_id, index) do
    user =
      %User{}
      |> User.changeset(%{
        email: "battery-member-#{index}@example.test",
        name: "Battery Member #{index}",
        role: :member
      })
      |> Repo.insert!()

    %AccountMembership{}
    |> AccountMembership.changeset(%{
      account_id: account_id,
      user_id: user.id,
      role: :member,
      status: :active,
      joined_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    user.id
  end

  defp restrictions!(member, user_id, ids) do
    if diet = member[:diet] do
      %UserDietaryProfile{}
      |> UserDietaryProfile.changeset(%{user_id: user_id, diet_type: diet, macro_goal: :balanced})
      |> Repo.insert!()
    end

    Enum.each(member[:allergies] || [], fn key ->
      %UserExcludedIngredient{}
      |> UserExcludedIngredient.changeset(%{
        user_id: user_id,
        ingredient_id: Map.fetch!(ids, key),
        reason: :allergy
      })
      |> Repo.insert!()
    end)
  end

  defp ingredient!(spec) do
    {:ok, ingredient} = Catalog.create_ingredient(%{name: spec.name, category: :otros})
    Enum.each(spec.tags, fn tag -> {:ok, _} = Catalog.tag_ingredient(ingredient.id, tag) end)
    ingredient
  end

  defp product!(spec, ids) do
    {quantity_milli, unit} = spec.package

    product =
      %Product{}
      |> Product.changeset(%{
        ingredient_id: Map.fetch!(ids, spec.ingredient),
        supermarket_id: supermarket!().id,
        name: spec.name,
        brand: spec[:brand],
        package_quantity_milli: quantity_milli,
        package_unit: unit
      })
      |> Repo.insert!()

    %PriceObservation{}
    |> PriceObservation.changeset(%{
      product_id: product.id,
      price_cents: spec.price_cents,
      currency: "ARS",
      observed_at: spec.observed_at
    })
    |> Repo.insert!()
  end

  defp supermarket! do
    case Repo.get_by(Supermarket, name: @supermarket) do
      nil -> %Supermarket{} |> Supermarket.changeset(%{name: @supermarket}) |> Repo.insert!()
      supermarket -> supermarket
    end
  end

  defp recipe!(spec, ids, slots) do
    {:ok, recipe} =
      Catalog.create_recipe(%{
        name: spec.name,
        description: spec[:description],
        servings: 2,
        suitable_for_slots: spec[:slots] || slots,
        source: :traditional,
        calories_per_serving: 500
      })

    Enum.each(spec.ingredients, fn ingredient ->
      {key, {quantity_milli, unit}} =
        case ingredient do
          {key, quantity} -> {key, quantity}
          key -> {key, {100_000, :g}}
        end

      {:ok, _} =
        Catalog.add_recipe_ingredient(%{
          recipe_id: recipe.id,
          ingredient_id: Map.fetch!(ids, key),
          quantity_milli: quantity_milli,
          unit: unit
        })
    end)

    recipe
  end

  defp pantry!(spec, account_id, ids) do
    now = DateTime.utc_now()

    %InventoryItem{}
    |> InventoryItem.changeset(%{
      account_id: account_id,
      ingredient_id: Map.fetch!(ids, spec.ingredient),
      quantity_milli: spec.quantity_milli,
      unit: spec.unit,
      source_kind: :extra,
      acquired_at: now,
      last_mutation_at: now
    })
    |> Repo.insert!()
  end

  defp planned_meal!(account_id, meal, recipe) do
    %ScheduledMeal{}
    |> ScheduledMeal.changeset(%{
      account_id: account_id,
      date: meal.date,
      slot: meal.slot,
      recipe_id: recipe.id,
      is_cooked: false,
      selected_quantity: 1
    })
    |> Repo.insert!()
  end
end
