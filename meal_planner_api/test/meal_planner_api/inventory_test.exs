defmodule MealPlannerApi.InventoryTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Inventory
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Inventory, as: PersistenceInventory
  alias MealPlannerApi.Persistence.Planning
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  test "available_for subtracts future reservations and releases past uncooked meals" do
    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{
        "user_id" => "u_inv_reserved",
        "account_id" => "acct_inv_reserved",
        "account_type" => "group",
        "subscription_tier" => "premium"
      })

    {:ok, %{user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: user.id,
        account_id: account.id,
        plan: :family_4
      })

    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Pollo Reserva Test",
        category: :carnes,
        calories_per_100: 239,
        protein_g_per_100: Decimal.new("27.0"),
        carbs_g_per_100: Decimal.new("0.0"),
        fat_g_per_100: Decimal.new("14.0")
      })

    {:ok, recipe_future} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: "Pollo mañana",
        source: :user_created,
        servings: 1,
        suitable_for_slots: [:lunch]
      })

    {:ok, _ri_future} =
      Catalog.add_recipe_ingredient(%{
        recipe_id: recipe_future.id,
        ingredient_id: ingredient.id,
        quantity_milli: 300,
        unit: :g
      })

    {:ok, recipe_past} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: "Pollo ayer",
        source: :user_created,
        servings: 1,
        suitable_for_slots: [:dinner]
      })

    {:ok, _ri_past} =
      Catalog.add_recipe_ingredient(%{
        recipe_id: recipe_past.id,
        ingredient_id: ingredient.id,
        quantity_milli: 200,
        unit: :g
      })

    tomorrow = Date.add(Date.utc_today(), 1)
    yesterday = Date.add(Date.utc_today(), -1)

    {:ok, _meal_future} =
      Planning.schedule_meal(%{
        account_id: account.id,
        date: tomorrow,
        slot: :lunch,
        recipe_id: recipe_future.id,
        is_cooked: false
      })

    {:ok, _meal_past} =
      Planning.schedule_meal(%{
        account_id: account.id,
        date: yesterday,
        slot: :dinner,
        recipe_id: recipe_past.id,
        is_cooked: false
      })

    {:ok, _inventory_item} =
      PersistenceInventory.apply_delta_and_log(%{
        account_id: account.id,
        ingredient_id: ingredient.id,
        unit: :g,
        source_kind: :planned,
        delta: 500,
        source_user_id: user_id,
        trigger_type: :purchase,
        operation: :add
      })

    available = Inventory.available_for(%{id: user.id, account_id: account.id}, %{})

    chicken_available =
      Enum.find(available, fn item -> item.ingredient_id == ingredient.id and item.unit == :g end)

    assert chicken_available.quantity_milli == 200
  end

  test "available_for excludes future reservations inside the requested range" do
    tomorrow = Date.add(Date.utc_today(), 1)

    %{user: user, ingredient: ingredient} =
      inventory_scenario(500, [{tomorrow, 300}])

    available = Inventory.available_for(user, %{exclude_range: {tomorrow, tomorrow}})

    assert [%{ingredient_id: ingredient_id, unit: :g, quantity_milli: 500}] = available
    assert ingredient_id == ingredient.id
  end

  test "available_for preserves future reservations outside the excluded range" do
    tomorrow = Date.add(Date.utc_today(), 1)
    after_window = Date.add(tomorrow, 1)

    %{user: user, ingredient: ingredient} =
      inventory_scenario(1_000, [{tomorrow, 300}, {after_window, 200}])

    available = Inventory.available_for(user, %{exclude_range: {tomorrow, tomorrow}})

    assert [%{ingredient_id: ingredient_id, unit: :g, quantity_milli: 800}] = available
    assert ingredient_id == ingredient.id
  end

  defp inventory_scenario(stock_quantity, reservations) do
    suffix = System.unique_integer([:positive])

    {:ok, %{user: user, account: account}} =
      Accounts.find_or_create_identity(%{
        "user_id" => "u_inv_range_#{suffix}",
        "account_id" => "acct_inv_range_#{suffix}",
        "account_type" => "group",
        "subscription_tier" => "premium"
      })

    {:ok, %{user_id: user_id}} =
      Identity.ensure_persistent_identity(%{
        id: user.id,
        account_id: account.id,
        plan: :family_4
      })

    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Range reservation ingredient #{suffix}",
        category: :carnes,
        calories_per_100: 100,
        protein_g_per_100: Decimal.new("10.0"),
        carbs_g_per_100: Decimal.new("0.0"),
        fat_g_per_100: Decimal.new("5.0")
      })

    Enum.with_index(reservations, fn {date, quantity}, index ->
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account.id,
          created_by_user_id: user.id,
          name: "Range reservation recipe #{suffix}-#{index}",
          source: :user_created,
          servings: 1,
          suitable_for_slots: [:lunch]
        })

      {:ok, _recipe_ingredient} =
        Catalog.add_recipe_ingredient(%{
          recipe_id: recipe.id,
          ingredient_id: ingredient.id,
          quantity_milli: quantity,
          unit: :g
        })

      {:ok, _meal} =
        Planning.schedule_meal(%{
          account_id: account.id,
          date: date,
          slot: :lunch,
          recipe_id: recipe.id,
          is_cooked: false
        })
    end)

    {:ok, _inventory_item} =
      PersistenceInventory.apply_delta_and_log(%{
        account_id: account.id,
        ingredient_id: ingredient.id,
        unit: :g,
        source_kind: :planned,
        delta: stock_quantity,
        source_user_id: user_id,
        trigger_type: :purchase,
        operation: :add
      })

    %{user: %{id: user.id, account_id: account.id}, ingredient: ingredient}
  end
end
