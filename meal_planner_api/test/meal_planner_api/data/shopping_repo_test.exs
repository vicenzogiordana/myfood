defmodule MealPlannerApi.Data.ShoppingRepoTest do
  @moduledoc """
  Tests for `MealPlannerApi.Data.ShoppingRepo` — Phase A — Tenancy
  Refactor, PR 2b task 2.15.

  Coverage:

    * `list_checkout_sessions/1` filters by `account_id` so a
      multi-familia User with sessions in Account A and Account B
      never sees the other account's sessions through either lookup.
    * `list_pending_delivery_sessions/1` filters by `account_id` AND
      status = :pending_delivery.
    * `get_checkout_session_for_account/2` refuses a `session_id`
      that belongs to a different account.
    * `list_shopping_items/1` correctly scopes to a checkout session
      (which is already validated to belong to the requested account
      by the caller).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Data.ShoppingRepo
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Catalog.Ingredient
  alias MealPlannerApi.Persistence.Shopping.CheckoutSession
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "list_checkout_sessions/1 — account_id scoping" do
    test "returns only the sessions for the requested account" do
      account_a = insert_account("Shop A")
      account_b = insert_account("Shop B")

      user = insert_user_with_active_membership(account_a.id, "shop-multi@example.com", :owner)
      _family_membership = insert_active_membership_for(account_b.id, user, :member)

      {:ok, session_a} =
        ShoppingRepo.create_checkout_session(%{
          account_id: account_a.id,
          status: :draft,
          checkout_type: :online
        })

      {:ok, session_a2} =
        ShoppingRepo.create_checkout_session(%{
          account_id: account_a.id,
          status: :pending_delivery,
          checkout_type: :online
        })

      {:ok, _session_b} =
        ShoppingRepo.create_checkout_session(%{
          account_id: account_b.id,
          status: :draft,
          checkout_type: :online
        })

      list_a = ShoppingRepo.list_checkout_sessions(account_a.id)
      list_b = ShoppingRepo.list_checkout_sessions(account_b.id)

      assert length(list_a) == 2
      assert Enum.all?(list_a, &(&1.account_id == account_a.id))

      assert Enum.map(list_a, & &1.id) |> Enum.sort() ==
               Enum.sort([session_a.id, session_a2.id])

      assert length(list_b) == 1
      assert hd(list_b).account_id == account_b.id
    end
  end

  describe "list_pending_delivery_sessions/1 — account_id + status scope" do
    test "returns only pending_delivery sessions for the requested account" do
      account_a = insert_account("Pending A")
      account_b = insert_account("Pending B")

      user = insert_user_with_active_membership(account_a.id, "pending@example.com", :owner)
      _family_membership = insert_active_membership_for(account_b.id, user, :member)

      {:ok, _draft_a} =
        ShoppingRepo.create_checkout_session(%{
          account_id: account_a.id,
          status: :draft,
          checkout_type: :online
        })

      {:ok, pending_a} =
        ShoppingRepo.create_checkout_session(%{
          account_id: account_a.id,
          status: :pending_delivery,
          checkout_type: :online
        })

      {:ok, _pending_b} =
        ShoppingRepo.create_checkout_session(%{
          account_id: account_b.id,
          status: :pending_delivery,
          checkout_type: :online
        })

      list_a = ShoppingRepo.list_pending_delivery_sessions(account_a.id)

      assert length(list_a) == 1
      assert hd(list_a).id == pending_a.id
      assert hd(list_a).account_id == account_a.id
      assert hd(list_a).status == :pending_delivery
    end
  end

  describe "get_checkout_session_for_account/2 — rejects cross-account session_ids" do
    test "returns the session when it belongs to the requested account" do
      account = insert_account("Self Shop")
      _user = insert_user_with_active_membership(account.id, "self-shop@example.com", :owner)

      {:ok, session} =
        ShoppingRepo.create_checkout_session(%{
          account_id: account.id,
          status: :draft,
          checkout_type: :online
        })

      fetched = ShoppingRepo.get_checkout_session_for_account(account.id, session.id)
      assert fetched.id == session.id
    end

    test "returns nil when the session belongs to a different account" do
      account_a = insert_account("Cross Shop A")
      account_b = insert_account("Cross Shop B")

      user = insert_user_with_active_membership(account_a.id, "cross-shop@example.com", :owner)
      _family_membership = insert_active_membership_for(account_b.id, user, :member)

      {:ok, _session_a} =
        ShoppingRepo.create_checkout_session(%{
          account_id: account_a.id,
          status: :draft,
          checkout_type: :online
        })

      {:ok, session_b} =
        ShoppingRepo.create_checkout_session(%{
          account_id: account_b.id,
          status: :draft,
          checkout_type: :online
        })

      assert ShoppingRepo.get_checkout_session_for_account(account_a.id, session_b.id) == nil
    end
  end

  describe "list_shopping_items/1 — scoped to checkout_session" do
    test "returns only items belonging to the given checkout_session" do
      account = insert_account("Items")
      user = insert_user_with_active_membership(account.id, "items@example.com", :owner)
      recipe = insert_recipe("Shop Recipe")
      scheduled_meal = insert_scheduled_meal(account.id, recipe.id, user.id)

      {:ok, session_a} =
        ShoppingRepo.create_checkout_session(%{
          account_id: account.id,
          status: :draft,
          checkout_type: :online
        })

      {:ok, session_b} =
        ShoppingRepo.create_checkout_session(%{
          account_id: account.id,
          status: :draft,
          checkout_type: :online
        })

      flour = insert_ingredient("Shop Flour")
      sugar = insert_ingredient("Shop Sugar")
      salt = insert_ingredient("Shop Salt")

      {:ok, _item_a1} =
        ShoppingRepo.create_shopping_item(%{
          account_id: account.id,
          checkout_session_id: session_a.id,
          scheduled_meal_id: scheduled_meal.id,
          planned_date: ~D[2026-07-01],
          ingredient_id: flour.id,
          quantity_milli: 1_000_000,
          unit: :g,
          status: :pending
        })

      {:ok, _item_a2} =
        ShoppingRepo.create_shopping_item(%{
          account_id: account.id,
          checkout_session_id: session_a.id,
          scheduled_meal_id: scheduled_meal.id,
          planned_date: ~D[2026-07-01],
          ingredient_id: sugar.id,
          quantity_milli: 500_000,
          unit: :g,
          status: :pending
        })

      {:ok, _item_b} =
        ShoppingRepo.create_shopping_item(%{
          account_id: account.id,
          checkout_session_id: session_b.id,
          scheduled_meal_id: scheduled_meal.id,
          planned_date: ~D[2026-07-01],
          ingredient_id: salt.id,
          quantity_milli: 100_000,
          unit: :g,
          status: :pending
        })

      list_a = ShoppingRepo.list_shopping_items(session_a.id)
      list_b = ShoppingRepo.list_shopping_items(session_b.id)

      assert length(list_a) == 2
      assert Enum.all?(list_a, &(&1.checkout_session_id == session_a.id))

      assert length(list_b) == 1
      assert hd(list_b).checkout_session_id == session_b.id
    end
  end

  # ---- helpers ---------------------------------------------------------------

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

    insert_active_membership_for(account_id, user, role)
    user
  end

  defp insert_active_membership_for(account_id, user, role) do
    %AccountMembership{}
    |> AccountMembership.changeset(%{
      account_id: account_id,
      user_id: user.id,
      role: role,
      status: :active,
      joined_at: DateTime.utc_now()
    })
    |> Repo.insert!()
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

  defp insert_scheduled_meal(account_id, recipe_id, _user_id) do
    Repo.insert!(%MealPlannerApi.Persistence.Planning.ScheduledMeal{
      account_id: account_id,
      recipe_id: recipe_id,
      date: ~D[2026-07-01],
      slot: :lunch,
      is_cooked: false
    })
  end
end
