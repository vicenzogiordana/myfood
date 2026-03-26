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
        account_type: :group
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
end
