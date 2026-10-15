defmodule MealPlannerApi.PlanningAgentFixtures do
  @moduledoc """
  Fictitious households, members, ingredients and recipes for planning agent
  tests. Every name is invented; nothing mirrors real data.
  """

  alias MealPlannerApi.Persistence.Accounts.{
    Account,
    AccountMembership,
    User,
    UserDietaryProfile,
    UserExcludedIngredient
  }

  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Inventory.InventoryItem
  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.Persistence.Shopping.{PriceObservation, Product, Supermarket}
  alias MealPlannerApi.PlanningAgent.Consent
  alias MealPlannerApi.Repo

  import MealPlannerApi.FactoryHelpers, only: [user_with_memberships: 2]

  @doc """
  Checks out a shared sandbox owned by a separate process and, on exit, waits
  for every Planning Session to end before the connection is released, so
  session processes never outlive the test's database access. A session
  outlives its last subscriber for the absence grace, so it is shut down
  rather than awaited.
  """
  def sandbox_sessions! do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    ExUnit.Callbacks.on_exit(fn ->
      sup = MealPlannerApi.PlanningAgent.SessionSupervisor

      for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
        DynamicSupervisor.terminate_child(sup, pid)
      end

      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  @doc "A Household with its Owner. Returns `%{account_id, owner}`."
  def household!(name \\ "Fictitious Household") do
    owner =
      user_with_memberships(%{email: unique_email()}, [{%{plan: :family_4, name: name}, :owner}])

    [membership] = owner.memberships

    %{account_id: membership.account_id, owner: member_map(owner, membership)}
  end

  @doc "Adds an active Member to the Household."
  def member!(%{account_id: account_id}, role \\ :member) do
    user =
      %User{}
      |> User.changeset(%{email: unique_email(), name: "Fictitious Member", role: :member})
      |> Repo.insert!()

    membership =
      %AccountMembership{}
      |> AccountMembership.changeset(%{
        account_id: account_id,
        user_id: user.id,
        role: role,
        status: :active,
        joined_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    member_map(user, membership)
  end

  @doc "Removes the Member from the Household, as the Owner's removal does."
  def remove_member!(member) do
    import Ecto.Query, only: [from: 2]
    {1, _} = Repo.delete_all(from(m in AccountMembership, where: m.id == ^member.membership_id))
    :ok
  end

  @doc "Session attributes for the given Member."
  def session_attrs(household, member, range, slots \\ ["lunch", "dinner"]) do
    %{
      account_id: household.account_id,
      user_id: member.user_id,
      membership_id: member.membership_id,
      role: member.role,
      range: range,
      slots: slots
    }
  end

  @doc "Sets the Household's grocery budget for a Planning Range, in cents."
  def budget!(%{account_id: account_id}, cents) do
    Account
    |> Repo.get!(account_id)
    |> Ecto.Changeset.change(default_budget_cents: cents)
    |> Repo.update!()
  end

  def consent!(household, member), do: :ok = Consent.record(household.account_id, member.user_id)

  def diet!(member, diet) do
    %UserDietaryProfile{}
    |> UserDietaryProfile.changeset(%{
      user_id: member.user_id,
      diet_type: diet,
      macro_goal: :balanced
    })
    |> Repo.insert!()
  end

  def allergy!(member, ingredient), do: exclusion!(member, ingredient, :allergy)
  def dislike!(member, ingredient), do: exclusion!(member, ingredient, :dislike)

  defp exclusion!(member, ingredient, reason) do
    %UserExcludedIngredient{}
    |> UserExcludedIngredient.changeset(%{
      user_id: member.user_id,
      ingredient_id: ingredient.id,
      reason: reason
    })
    |> Repo.insert!()
  end

  @doc """
  A catalog Ingredient with a unique name, its reviewed `tags` and optional
  nutrition `attrs` per 100 g/ml (`calories_per_100`, `protein_g_per_100`,
  `carbs_g_per_100`, `fat_g_per_100`).
  """
  def ingredient!(name, tags \\ [], attrs \\ %{}) do
    {:ok, ingredient} =
      %{name: "#{name} #{unique()}", category: :otros}
      |> Map.merge(attrs)
      |> Catalog.create_ingredient()

    Enum.each(tags, fn tag -> {:ok, _} = Catalog.tag_ingredient(ingredient.id, tag) end)
    ingredient
  end

  def recipe!(name, ingredients, opts \\ []) do
    {:ok, recipe} =
      Catalog.create_recipe(%{
        name: name,
        servings: 2,
        suitable_for_slots: Keyword.get(opts, :slots, ["lunch", "dinner"]),
        source: :traditional,
        account_id: Keyword.get(opts, :account_id),
        calories_per_serving: 500
      })

    # `:quantities` maps an ingredient id to `{quantity_milli, unit}`;
    # every other ingredient uses 100 g.
    quantities = Keyword.get(opts, :quantities, %{})

    Enum.each(ingredients, fn ingredient ->
      {quantity_milli, unit} = Map.get(quantities, ingredient.id, {100_000, :g})

      {:ok, _} =
        Catalog.add_recipe_ingredient(%{
          recipe_id: recipe.id,
          ingredient_id: ingredient.id,
          quantity_milli: quantity_milli,
          unit: unit
        })
    end)

    recipe
  end

  def scheduled_meal!(household, date, slot, recipe, opts \\ []) do
    %ScheduledMeal{}
    |> ScheduledMeal.changeset(%{
      account_id: household.account_id,
      date: date,
      slot: slot,
      recipe_id: recipe.id,
      is_cooked: Keyword.get(opts, :is_cooked, false),
      selected_quantity: Keyword.get(opts, :selected_quantity, 1)
    })
    |> Repo.insert!()
  end

  @doc """
  A Product covering `ingredient` with one Price Observation.

  Options: `:name`, `:brand`, `:package` (`{quantity_milli, unit}`, default
  1 kg), `:price_cents`, `:currency` (default `"ARS"`), `:observed_at` and
  `:supermarket` (a name; created when missing).
  """
  def product!(ingredient, opts \\ []) do
    {quantity_milli, unit} = Keyword.get(opts, :package, {1_000_000, :g})

    supermarket =
      supermarket!(Keyword.get(opts, :supermarket, "Fictitious Market #{unique()}"))

    product =
      %Product{}
      |> Product.changeset(%{
        ingredient_id: ingredient.id,
        supermarket_id: supermarket.id,
        name: Keyword.get(opts, :name, "#{ingredient.name} pack"),
        brand: Keyword.get(opts, :brand),
        package_quantity_milli: quantity_milli,
        package_unit: unit
      })
      |> Repo.insert!()

    price_observation!(product, Keyword.get(opts, :price_cents, 1_000), opts)
    product
  end

  @doc "Adds a Price Observation to `product`."
  def price_observation!(product, price_cents, opts \\ []) do
    %PriceObservation{}
    |> PriceObservation.changeset(%{
      product_id: product.id,
      price_cents: price_cents,
      currency: Keyword.get(opts, :currency, "ARS"),
      observed_at: Keyword.get(opts, :observed_at, ~U[2026-10-14 10:00:00.000000Z])
    })
    |> Repo.insert!()
  end

  defp supermarket!(name) do
    case Repo.get_by(Supermarket, name: name) do
      nil -> %Supermarket{} |> Supermarket.changeset(%{name: name}) |> Repo.insert!()
      supermarket -> supermarket
    end
  end

  @doc "A usable Pantry lot of `ingredient` for the Household."
  def pantry!(household, ingredient, quantity_milli, unit \\ :g, opts \\ []) do
    %InventoryItem{}
    |> InventoryItem.changeset(%{
      account_id: household.account_id,
      ingredient_id: ingredient.id,
      quantity_milli: quantity_milli,
      unit: unit,
      source_kind: :extra,
      acquired_at: DateTime.utc_now(),
      expired_at: Keyword.get(opts, :expired_at),
      last_mutation_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp member_map(user, membership) do
    %{user_id: user.id, membership_id: membership.id, role: membership.role}
  end

  defp unique_email, do: "fictitious-#{unique()}@example.test"
  defp unique, do: System.unique_integer([:positive])
end
