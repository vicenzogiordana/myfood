defmodule MealPlannerApi.ShoppingServiceTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Planning
  alias MealPlannerApi.Persistence.Shopping
  alias MealPlannerApi.Services.ShoppingService
  alias MealPlannerApi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  defp create_test_ingredient(account_id) do
    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "Test Ingredient #{:rand.uniform(10000)}",
        category: :carnes,
        calories_per_100: 250,
        protein_g_per_100: Decimal.new("26.0"),
        carbs_g_per_100: Decimal.new("0.0"),
        fat_g_per_100: Decimal.new("15.0")
      })

    ingredient
  end

  defp create_test_recipe(account_id, user_id) do
    {:ok, recipe} =
      Catalog.create_recipe(%{
        account_id: account_id,
        created_by_user_id: user_id,
        name: "Test Recipe #{:rand.uniform(10000)}",
        source: :user_created,
        servings: 2,
        suitable_for_slots: [:lunch]
      })

    {:ok, _step} =
      Catalog.add_recipe_step(%{
        recipe_id: recipe.id,
        step_number: 1,
        instructions: "Cook it",
        duration_minutes: 20
      })

    recipe
  end

  # ==========================================================================
  # TASK-11: Tests for confirm_checkout transaction and get_shopping_list pruning
  # ==========================================================================

  describe "confirm_checkout/3" do
    test "wraps in transaction and calls move_items_to_inventory" do
      {:ok, identity} =
        Identity.ensure_persistent_identity(%{
          id: "u_checkout_txn_#{:rand.uniform(10000)}",
          account_id: "acct_checkout_txn_#{:rand.uniform(10000)}",
          account_type: :group
        })

      account_id = identity.account_id
      user = %{id: identity.user_id, account_id: account_id, account_type: :group}

      ingredient = create_test_ingredient(account_id)
      recipe = create_test_recipe(account_id, identity.user_id)

      {:ok, _ri} =
        Catalog.add_recipe_ingredient(%{
          recipe_id: recipe.id,
          ingredient_id: ingredient.id,
          quantity_milli: 500,
          unit: :g
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

      {:ok, _item} =
        Shopping.create_shopping_item(%{
          account_id: account_id,
          scheduled_meal_id: meal.id,
          checkout_session_id: session.id,
          planned_date: Date.utc_today(),
          ingredient_id: ingredient.id,
          quantity_milli: 500,
          unit: :g,
          status: :checked_out
        })

      result = ShoppingService.confirm_checkout(user, session.id, %{"actual_total_cents" => 5000})

      assert {:ok, response} = result
      assert response.status == "completed"
      assert response.moved_to_inventory_count >= 0
    end

    test "returns moved_to_inventory_count in response" do
      {:ok, identity} =
        Identity.ensure_persistent_identity(%{
          id: "u_count_#{:rand.uniform(10000)}",
          account_id: "acct_count_#{:rand.uniform(10000)}",
          account_type: :group
        })

      account_id = identity.account_id
      user = %{id: identity.user_id, account_id: account_id, account_type: :group}

      ingredient = create_test_ingredient(account_id)
      recipe = create_test_recipe(account_id, identity.user_id)

      {:ok, _ri} =
        Catalog.add_recipe_ingredient(%{
          recipe_id: recipe.id,
          ingredient_id: ingredient.id,
          quantity_milli: 300,
          unit: :g
        })

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: account_id,
          date: Date.utc_today(),
          slot: :dinner,
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
          ingredient_id: ingredient.id,
          quantity_milli: 200,
          unit: :g,
          status: :checked_out
        })

      {:ok, _item2} =
        Shopping.create_shopping_item(%{
          account_id: account_id,
          scheduled_meal_id: meal.id,
          checkout_session_id: session.id,
          planned_date: Date.utc_today(),
          ingredient_id: ingredient.id,
          quantity_milli: 100,
          unit: :g,
          status: :checked_out
        })

      result = ShoppingService.confirm_checkout(user, session.id, %{"actual_total_cents" => 3000})

      assert {:ok, response} = result
      assert Map.has_key?(response, :moved_to_inventory_count)
      assert is_integer(response.moved_to_inventory_count)
    end

    test "rolls back and returns transaction_failed on session update failure" do
      {:ok, identity} =
        Identity.ensure_persistent_identity(%{
          id: "u_rollback_#{:rand.uniform(10000)}",
          account_id: "acct_rollback_#{:rand.uniform(10000)}",
          account_type: :group
        })

      user = %{id: identity.user_id, account_id: identity.account_id, account_type: :group}

      # Try to confirm a non-existent session
      fake_session_id = Ecto.UUID.generate()

      result =
        ShoppingService.confirm_checkout(user, fake_session_id, %{"actual_total_cents" => 1000})

      # Should return error for session not found
      assert result == {:error, :session_not_found}
    end
  end

  describe "get_shopping_list/2" do
    test "archives past-dated pending items on every call" do
      {:ok, identity} =
        Identity.ensure_persistent_identity(%{
          id: "u_archive_#{:rand.uniform(10000)}",
          account_id: "acct_archive_#{:rand.uniform(10000)}",
          account_type: :group
        })

      account_id = identity.account_id
      user = %{id: identity.user_id, account_id: account_id, account_type: :group}

      ingredient = create_test_ingredient(account_id)
      recipe = create_test_recipe(account_id, identity.user_id)

      {:ok, _ri} =
        Catalog.add_recipe_ingredient(%{
          recipe_id: recipe.id,
          ingredient_id: ingredient.id,
          quantity_milli: 200,
          unit: :g
        })

      past_date = Date.add(Date.utc_today(), -5)

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: account_id,
          date: past_date,
          slot: :breakfast,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, _item} =
        Shopping.create_shopping_item(%{
          account_id: account_id,
          scheduled_meal_id: meal.id,
          planned_date: past_date,
          ingredient_id: ingredient.id,
          quantity_milli: 200,
          unit: :g,
          status: :pending
        })

      # Verify item was created with correct status before calling get_shopping_list
      items_before = Shopping.list_items_for_account(account_id, include_archived: true)
      pending_items_before = Enum.filter(items_before, &(&1.status == :pending))
      assert length(pending_items_before) >= 1, "Item should be created with pending status"

      # Call get_shopping_list with today's date range
      today = Date.utc_today()

      {:ok, _response} =
        ShoppingService.get_shopping_list(user, %{
          "from_date" => Date.to_iso8601(today),
          "to_date" => Date.to_iso8601(Date.add(today, 6))
        })

      # Check that the past item was archived
      items = Shopping.list_items_for_account(account_id, include_archived: true)
      archived_items = Enum.filter(items, &(&1.status == :archived))
      assert length(archived_items) >= 1
    end

    test "excludes archived items by default" do
      {:ok, identity} =
        Identity.ensure_persistent_identity(%{
          id: "u_exclude_#{:rand.uniform(10000)}",
          account_id: "acct_exclude_#{:rand.uniform(10000)}",
          account_type: :group
        })

      account_id = identity.account_id
      user = %{id: identity.user_id, account_id: account_id, account_type: :group}

      ingredient = create_test_ingredient(account_id)
      recipe = create_test_recipe(account_id, identity.user_id)

      {:ok, _ri} =
        Catalog.add_recipe_ingredient(%{
          recipe_id: recipe.id,
          ingredient_id: ingredient.id,
          quantity_milli: 150,
          unit: :ml
        })

      past_date = Date.add(Date.utc_today(), -3)

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: account_id,
          date: past_date,
          slot: :lunch,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, _item} =
        Shopping.create_shopping_item(%{
          account_id: account_id,
          scheduled_meal_id: meal.id,
          planned_date: past_date,
          ingredient_id: ingredient.id,
          quantity_milli: 150,
          unit: :ml,
          status: :pending
        })

      # Trigger archiving by calling get_shopping_list
      today = Date.utc_today()

      {:ok, response} =
        ShoppingService.get_shopping_list(user, %{
          "from_date" => Date.to_iso8601(today),
          "to_date" => Date.to_iso8601(Date.add(today, 6))
        })

      # By default, archived items should not appear in the list
      item_ingredient_ids = Enum.map(response.items, & &1.ingredient_id)
      refute Enum.member?(item_ingredient_ids, ingredient.id)
    end

    test "includes archived when include_archived=true" do
      {:ok, identity} =
        Identity.ensure_persistent_identity(%{
          id: "u_include_#{:rand.uniform(10000)}",
          account_id: "acct_include_#{:rand.uniform(10000)}",
          account_type: :group
        })

      account_id = identity.account_id
      user = %{id: identity.user_id, account_id: account_id, account_type: :group}

      ingredient = create_test_ingredient(account_id)
      recipe = create_test_recipe(account_id, identity.user_id)

      {:ok, _ri} =
        Catalog.add_recipe_ingredient(%{
          recipe_id: recipe.id,
          ingredient_id: ingredient.id,
          quantity_milli: 100,
          unit: :unit
        })

      past_date = Date.add(Date.utc_today(), -2)

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: account_id,
          date: past_date,
          slot: :dinner,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, _archived_item} =
        Shopping.create_shopping_item(%{
          account_id: account_id,
          scheduled_meal_id: meal.id,
          planned_date: past_date,
          ingredient_id: ingredient.id,
          quantity_milli: 100,
          unit: :unit,
          status: :archived
        })

      # With include_archived=true, archived items should be included
      today = Date.utc_today()

      {:ok, response_with} =
        ShoppingService.get_shopping_list(user, %{
          "from_date" => Date.to_iso8601(today),
          "to_date" => Date.to_iso8601(Date.add(today, 6)),
          "include_archived" => "true"
        })

      # Check archived_count in the response
      assert response_with.archived_count >= 1
    end
  end
end
