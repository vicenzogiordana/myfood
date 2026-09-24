defmodule MealPlannerApi.Data.ShoppingRepo.DeletePendingForWindowTest do
  @moduledoc """
  Tests for ShoppingRepo.delete_pending_for_window/3.
  Spec: AC #36.2 / story 14 — window wipe preserving terminal items.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Data.ShoppingRepo
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Catalog.Ingredient
  alias MealPlannerApi.Persistence.Shopping.ShoppingItem
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    account = insert_account("wipe-test")
    _user = insert_user_with_active_membership(account.id, "wipe@example.com", :owner)
    ingredient = insert_ingredient("flour")
    recipe = insert_recipe("bread")
    meal = insert_scheduled_meal(account.id, recipe.id, ~D[2026-09-25])

    checkout =
      Repo.insert!(%MealPlannerApi.Persistence.Shopping.CheckoutSession{
        account_id: account.id,
        status: :draft,
        checkout_type: :physical
      })

    %{
      account: account,
      ingredient: ingredient,
      meal: meal,
      checkout: checkout,
      range_from: ~D[2026-09-24],
      range_to: ~D[2026-09-26]
    }
  end

  # -------------------------------------------------------------------------
  # Scenario: wipes pending + in_cart, preserves checked_out + archived
  # -------------------------------------------------------------------------

  describe "delete_pending_for_window/3 — status preservation" do
    test "deletes :pending and :in_cart, preserves :checked_out and :archived", ctx do
      pending = insert_item(ctx, :pending, ~D[2026-09-25])
      in_cart = insert_item(ctx, :in_cart, ~D[2026-09-25])
      checked_out = insert_item(ctx, :checked_out, ~D[2026-09-25])
      archived = insert_item(ctx, :archived, ~D[2026-09-25])

      {deleted, _} =
        ShoppingRepo.delete_pending_for_window(ctx.account.id, ctx.range_from, ctx.range_to)

      assert deleted == 2
      assert Repo.get(ShoppingItem, pending.id) == nil
      assert Repo.get(ShoppingItem, in_cart.id) == nil
      assert Repo.get(ShoppingItem, checked_out.id) != nil
      assert Repo.get(ShoppingItem, archived.id) != nil
    end
  end

  # -------------------------------------------------------------------------
  # Scenario: scoped to account + range
  # -------------------------------------------------------------------------

  describe "delete_pending_for_window/3 — scoping" do
    test "only deletes within the date range", ctx do
      inside = insert_item(ctx, :pending, ~D[2026-09-25])
      outside = insert_item(ctx, :pending, ~D[2026-09-30])

      {deleted, _} =
        ShoppingRepo.delete_pending_for_window(ctx.account.id, ctx.range_from, ctx.range_to)

      assert deleted == 1
      assert Repo.get(ShoppingItem, inside.id) == nil
      assert Repo.get(ShoppingItem, outside.id) != nil
    end

    test "does not affect other accounts", ctx do
      other_account = insert_account("other-wipe")

      _other_user =
        insert_user_with_active_membership(other_account.id, "other-wipe@example.com", :owner)

      other_recipe = insert_recipe("other-bread")
      other_meal = insert_scheduled_meal(other_account.id, other_recipe.id, ~D[2026-09-25])

      other_checkout =
        Repo.insert!(%MealPlannerApi.Persistence.Shopping.CheckoutSession{
          account_id: other_account.id,
          status: :draft,
          checkout_type: :physical
        })

      other_item =
        Repo.insert!(%ShoppingItem{
          account_id: other_account.id,
          scheduled_meal_id: other_meal.id,
          planned_date: ~D[2026-09-25],
          ingredient_id: ctx.ingredient.id,
          quantity_milli: 100_000,
          unit: :g,
          checkout_session_id: other_checkout.id,
          status: :pending
        })

      _own_item = insert_item(ctx, :pending, ~D[2026-09-25])

      {deleted, _} =
        ShoppingRepo.delete_pending_for_window(ctx.account.id, ctx.range_from, ctx.range_to)

      assert deleted == 1
      assert Repo.get(ShoppingItem, other_item.id) != nil
    end
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp insert_item(ctx, status, date) do
    Repo.insert!(%ShoppingItem{
      account_id: ctx.account.id,
      scheduled_meal_id: ctx.meal.id,
      planned_date: date,
      ingredient_id: ctx.ingredient.id,
      quantity_milli: 100_000,
      unit: :g,
      checkout_session_id: ctx.checkout.id,
      status: status
    })
  end

  defp insert_account(name) do
    plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

    {:ok, account} =
      %PersistenceAccount{}
      |> PersistenceAccount.changeset(%{
        name: name,
        plan: :family_4,
        default_budget_cents: 0,
        subscription_plan_id: plan.id
      })
      |> Repo.insert()

    account
  end

  defp insert_user_with_active_membership(account_id, email, role) do
    user =
      %PersistenceUser{}
      |> PersistenceUser.changeset(%{email: email, name: email, role: role})
      |> Repo.insert!()

    %AccountMembership{}
    |> AccountMembership.changeset(%{
      account_id: account_id,
      user_id: user.id,
      role: role,
      status: :active,
      joined_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    user
  end

  defp insert_ingredient(name) do
    %Ingredient{}
    |> Ingredient.changeset(%{name: name, category: :otros})
    |> Repo.insert!()
  end

  defp insert_recipe(name) do
    %MealPlannerApi.Persistence.Catalog.Recipe{}
    |> MealPlannerApi.Persistence.Catalog.Recipe.changeset(%{
      name: name,
      description: "Test recipe",
      servings: 2,
      cooking_time_minutes: 30,
      suitable_for_slots: ["lunch", "dinner"],
      source: :user_created,
      created_by_user_id: nil
    })
    |> Repo.insert!()
  end

  defp insert_scheduled_meal(account_id, recipe_id, date) do
    Repo.insert!(%MealPlannerApi.Persistence.Planning.ScheduledMeal{
      account_id: account_id,
      recipe_id: recipe_id,
      date: date,
      slot: :lunch,
      is_cooked: false
    })
  end
end
