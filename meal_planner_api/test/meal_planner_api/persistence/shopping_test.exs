defmodule MealPlannerApi.Persistence.ShoppingTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Planning
  alias MealPlannerApi.Persistence.Shopping
  alias MealPlannerApi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  # ==========================================================================
  # TASK-12: Tests for list_items_by_session
  # ==========================================================================

  describe "list_items_by_session/2" do
    test "returns all items for a given checkout_session_id" do
      {:ok, identity} =
        Identity.ensure_persistent_identity(%{
          id: "u_session_items_#{:rand.uniform(10000)}",
          account_id: "acct_session_items_#{:rand.uniform(10000)}",
          plan: :family_4
        })

      account_id = identity.account_id

      {:ok, ingredient1} =
        Catalog.upsert_ingredient_by_name(%{
          name: "Test Ingredient 1 #{:rand.uniform(10000)}",
          category: :carnes,
          calories_per_100: 250,
          protein_g_per_100: Decimal.new("26.0"),
          carbs_g_per_100: Decimal.new("0.0"),
          fat_g_per_100: Decimal.new("15.0")
        })

      {:ok, ingredient2} =
        Catalog.upsert_ingredient_by_name(%{
          name: "Test Ingredient 2 #{:rand.uniform(10000)}",
          category: :verduras,
          calories_per_100: 50,
          protein_g_per_100: Decimal.new("2.0"),
          carbs_g_per_100: Decimal.new("10.0"),
          fat_g_per_100: Decimal.new("0.5")
        })

      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account_id,
          created_by_user_id: identity.user_id,
          name: "Test Recipe #{:rand.uniform(10000)}",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: account_id,
          date: Date.utc_today(),
          slot: :lunch,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, session} =
        Shopping.create_checkout_session(%{
          account_id: account_id,
          status: :draft,
          checkout_type: :physical,
          started_at: DateTime.utc_now()
        })

      {:ok, _item1} =
        Shopping.create_shopping_item(%{
          account_id: account_id,
          scheduled_meal_id: meal.id,
          checkout_session_id: session.id,
          planned_date: Date.utc_today(),
          ingredient_id: ingredient1.id,
          quantity_milli: 500,
          unit: :g,
          status: :pending
        })

      {:ok, _item2} =
        Shopping.create_shopping_item(%{
          account_id: account_id,
          scheduled_meal_id: meal.id,
          checkout_session_id: session.id,
          planned_date: Date.utc_today(),
          ingredient_id: ingredient2.id,
          quantity_milli: 300,
          unit: :g,
          status: :in_cart
        })

      items = Shopping.list_items_by_session(account_id, session.id)

      assert length(items) == 2
      assert Enum.any?(items, &(&1.ingredient_id == ingredient1.id))
      assert Enum.any?(items, &(&1.ingredient_id == ingredient2.id))
    end

    test "handles empty session (returns empty list)" do
      {:ok, identity} =
        Identity.ensure_persistent_identity(%{
          id: "u_empty_session_#{:rand.uniform(10000)}",
          account_id: "acct_empty_session_#{:rand.uniform(10000)}",
          plan: :family_4
        })

      account_id = identity.account_id
      fake_session_id = Ecto.UUID.generate()

      items = Shopping.list_items_by_session(account_id, fake_session_id)

      assert items == []
    end

    test "returns only items for the specified session (not all account items)" do
      {:ok, identity} =
        Identity.ensure_persistent_identity(%{
          id: "u_other_session_#{:rand.uniform(10000)}",
          account_id: "acct_other_session_#{:rand.uniform(10000)}",
          plan: :family_4
        })

      account_id = identity.account_id

      {:ok, ingredient} =
        Catalog.upsert_ingredient_by_name(%{
          name: "Test Ingredient Filter #{:rand.uniform(10000)}",
          category: :frutas,
          calories_per_100: 30,
          protein_g_per_100: Decimal.new("0.5"),
          carbs_g_per_100: Decimal.new("7.0"),
          fat_g_per_100: Decimal.new("0.2")
        })

      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: account_id,
          created_by_user_id: identity.user_id,
          name: "Test Recipe Filter #{:rand.uniform(10000)}",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: account_id,
          date: Date.utc_today(),
          slot: :lunch,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, session1} =
        Shopping.create_checkout_session(%{
          account_id: account_id,
          status: :draft,
          checkout_type: :physical,
          started_at: DateTime.utc_now()
        })

      {:ok, session2} =
        Shopping.create_checkout_session(%{
          account_id: account_id,
          status: :draft,
          checkout_type: :physical,
          started_at: DateTime.utc_now()
        })

      {:ok, _item_in_session1} =
        Shopping.create_shopping_item(%{
          account_id: account_id,
          scheduled_meal_id: meal.id,
          checkout_session_id: session1.id,
          planned_date: Date.utc_today(),
          ingredient_id: ingredient.id,
          quantity_milli: 100,
          unit: :g,
          status: :pending
        })

      # Item without session (or different session)
      {:ok, _item_no_session} =
        Shopping.create_shopping_item(%{
          account_id: account_id,
          scheduled_meal_id: meal.id,
          planned_date: Date.utc_today(),
          ingredient_id: ingredient.id,
          quantity_milli: 200,
          unit: :g,
          status: :pending
        })

      items_session1 = Shopping.list_items_by_session(account_id, session1.id)
      items_session2 = Shopping.list_items_by_session(account_id, session2.id)

      assert length(items_session1) == 1
      assert length(items_session2) == 0
    end
  end
end
