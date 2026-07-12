defmodule MealPlannerApi.Data.PlanningRepoTest do
  @moduledoc """
  Tests for `MealPlannerApi.Data.PlanningRepo` — Phase A — Tenancy
  Refactor, PR 2b task 2.13.

  Coverage:

    * `list_scheduled_meals/3` filters by `account_id` — a multi-familia
      User with meals in Account A and Account B does NOT leak meals
      across the boundary.
    * `list_uncooked_scheduled_meals/3` and
      `list_uncooked_scheduled_meals_with_recipe_ingredients/3` apply
      the same filter; the latter also asserts the
      `recipe -> recipe_ingredients -> ingredient` preload chain.
    * `get_scheduled_meal_for_account/2` rejects a `meal_id` that
      belongs to another account even when the caller has access to
      both.
    * `toggle_slot_favorite/1`, `is_slot_favorite?/4`, and
      `list_slot_favorites/2` — create/remove round-trip plus
      account_id scoping (PR 2b post-review fix pass item 7). This
      surfaced and fixed two real pre-existing production bugs: (1)
      `toggle_slot_favorite/1`'s create branch pattern-matched only
      `account_id/user_id/date/slot` from its input map and silently
      dropped the required `scheduled_meal_id`/`recipe_id` fields, so a
      favorite could never actually be created; (2)
      `SlotFavorite.changeset/2` validated the `:string` `:slot` field
      against a list of atoms, so `validate_inclusion` always failed
      for the string values every real caller passes.

  Pre-PR-2b the existing test only asserted function arity (smoke
  tests). This PR replaces them with real behavioral assertions.

  StreamData was suggested in `tasks.md` but is not in the dependency
  tree; this file uses deterministic fixtures for the multi-familia
  scenario instead.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Catalog.Ingredient
  alias MealPlannerApi.Persistence.Catalog.Recipe
  alias MealPlannerApi.Persistence.Catalog.RecipeIngredient
  alias MealPlannerApi.Persistence.Planning.ScheduledMeal
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "list_scheduled_meals/3 — account_id scoping" do
    test "returns only the meals for the requested account, not other accounts the user belongs to" do
      account_a = insert_account("Family A")
      account_b = insert_account("Family B")

      multi_user =
        insert_user_with_active_membership(account_a.id, "multi@example.com", :owner)

      _family_membership =
        insert_active_membership_for(account_b.id, multi_user, :member)

      recipe_a = insert_recipe("Recipe A")
      recipe_b = insert_recipe("Recipe B")

      {:ok, meal_a1} =
        PlanningRepo.schedule_meal(%{
          account_id: account_a.id,
          recipe_id: recipe_a.id,
          user_id: multi_user.id,
          date: ~D[2026-07-01],
          slot: :lunch,
          servings: 2
        })

      {:ok, meal_a2} =
        PlanningRepo.schedule_meal(%{
          account_id: account_a.id,
          recipe_id: recipe_a.id,
          user_id: multi_user.id,
          date: ~D[2026-07-02],
          slot: :dinner,
          servings: 4
        })

      {:ok, _meal_b1} =
        PlanningRepo.schedule_meal(%{
          account_id: account_b.id,
          recipe_id: recipe_b.id,
          user_id: multi_user.id,
          date: ~D[2026-07-01],
          slot: :lunch,
          servings: 3
        })

      list_a =
        PlanningRepo.list_scheduled_meals(account_a.id, ~D[2026-07-01], ~D[2026-07-31])

      list_b =
        PlanningRepo.list_scheduled_meals(account_b.id, ~D[2026-07-01], ~D[2026-07-31])

      assert length(list_a) == 2
      assert Enum.all?(list_a, &(&1.account_id == account_a.id))
      assert Enum.map(list_a, & &1.id) |> Enum.sort() ==
               Enum.sort([meal_a1.id, meal_a2.id])

      assert length(list_b) == 1
      assert hd(list_b).account_id == account_b.id
    end

    test "returns an empty list when the account has no meals in the date range" do
      account = insert_account("Empty")

      assert PlanningRepo.list_scheduled_meals(account.id, ~D[2026-07-01], ~D[2026-07-31]) == []
    end
  end

  describe "list_uncooked_scheduled_meals/3 — account_id scoping" do
    test "filters by account_id AND is_cooked = false" do
      account_a = insert_account("Uncooked A")
      account_b = insert_account("Uncooked B")

      user = insert_user_with_active_membership(account_a.id, "uncooked@example.com", :owner)
      _family_membership = insert_active_membership_for(account_b.id, user, :member)

      recipe = insert_recipe("Lunch")

      {:ok, uncooked_a} =
        PlanningRepo.schedule_meal(%{
          account_id: account_a.id,
          recipe_id: recipe.id,
          user_id: user.id,
          date: ~D[2026-07-01],
          slot: :lunch,
          servings: 2,
          is_cooked: false
        })

      {:ok, cooked_a} =
        PlanningRepo.schedule_meal(%{
          account_id: account_a.id,
          recipe_id: recipe.id,
          user_id: user.id,
          date: ~D[2026-07-02],
          slot: :lunch,
          servings: 2,
          is_cooked: true
        })

      {:ok, _uncooked_b} =
        PlanningRepo.schedule_meal(%{
          account_id: account_b.id,
          recipe_id: recipe.id,
          user_id: user.id,
          date: ~D[2026-07-01],
          slot: :lunch,
          servings: 2,
          is_cooked: false
        })

      list_a =
        PlanningRepo.list_uncooked_scheduled_meals(account_a.id, ~D[2026-07-01], ~D[2026-07-31])

      assert length(list_a) == 1
      assert hd(list_a).id == uncooked_a.id
      refute Enum.any?(list_a, &(&1.id == cooked_a.id))
      refute Enum.any?(list_a, &(&1.account_id == account_b.id))
    end
  end

  describe "get_scheduled_meal_for_account/2 — rejects cross-account meal ids" do
    test "returns nil when the meal_id belongs to a different account" do
      account_a = insert_account("Cross A")
      account_b = insert_account("Cross B")

      user = insert_user_with_active_membership(account_a.id, "cross@example.com", :owner)
      _family_membership = insert_active_membership_for(account_b.id, user, :member)

      recipe = insert_recipe("Dinner")

      {:ok, meal_a} =
        PlanningRepo.schedule_meal(%{
          account_id: account_a.id,
          recipe_id: recipe.id,
          user_id: user.id,
          date: ~D[2026-07-01],
          slot: :dinner,
          servings: 2
        })

      {:ok, meal_b} =
        PlanningRepo.schedule_meal(%{
          account_id: account_b.id,
          recipe_id: recipe.id,
          user_id: user.id,
          date: ~D[2026-07-01],
          slot: :dinner,
          servings: 2
        })

      # Canonical lookup: meal_a with account_a scope → returns the meal.
      assert PlanningRepo.get_scheduled_meal_for_account(account_a.id, meal_a.id).id ==
               meal_a.id

      # Cross-account: meal_b with account_a scope → returns nil.
      assert PlanningRepo.get_scheduled_meal_for_account(account_a.id, meal_b.id) == nil
    end

    test "returns the meal when the meal belongs to the requested account" do
      account = insert_account("Self")
      user = insert_user_with_active_membership(account.id, "self@example.com", :owner)
      recipe = insert_recipe("Self Recipe")

      {:ok, meal} =
        PlanningRepo.schedule_meal(%{
          account_id: account.id,
          recipe_id: recipe.id,
          user_id: user.id,
          date: ~D[2026-07-01],
          slot: :lunch,
          servings: 2
        })

      fetched = PlanningRepo.get_scheduled_meal_for_account(account.id, meal.id)
      assert fetched.id == meal.id
    end
  end

  describe "fetch_owned_proposal/3 — account_id + user_id scoping" do
    test "rejects a proposal that belongs to a different account" do
      account_a = insert_account("Proposal A")
      account_b = insert_account("Proposal B")

      user_a = insert_user_with_active_membership(account_a.id, "prop-a@example.com", :owner)
      user_b = insert_user_with_active_membership(account_b.id, "prop-b@example.com", :owner)

      proposal_a = insert_proposal(account_a.id, user_a.id, "A-Proposal")
      _proposal_b = insert_proposal(account_b.id, user_b.id, "B-Proposal")

      # Asking for the A proposal with account_b scope returns :proposal_not_found.
      assert {:error, :proposal_not_found} =
               PlanningRepo.fetch_owned_proposal(proposal_a.id, account_b.id, user_b.id)

      # And the canonical lookup (account_a, user_a) succeeds.
      assert {:ok, _proposal, _run} =
               PlanningRepo.fetch_owned_proposal(proposal_a.id, account_a.id, user_a.id)
    end
  end

  describe "list_uncooked_scheduled_meals_with_recipe_ingredients/3 — account_id scoping" do
    test "filters by account_id, is_cooked = false, and preloads recipe ingredients" do
      account_a = insert_account("Ingredients A")
      account_b = insert_account("Ingredients B")

      user = insert_user_with_active_membership(account_a.id, "ingredients@example.com", :owner)
      _family_membership = insert_active_membership_for(account_b.id, user, :member)

      flour = insert_ingredient("Flour")
      recipe = insert_recipe("Bread")
      insert_recipe_ingredient(recipe, flour, 200)

      {:ok, uncooked_a} =
        PlanningRepo.schedule_meal(%{
          account_id: account_a.id,
          recipe_id: recipe.id,
          user_id: user.id,
          date: ~D[2026-07-01],
          slot: :lunch,
          servings: 2,
          is_cooked: false
        })

      {:ok, cooked_a} =
        PlanningRepo.schedule_meal(%{
          account_id: account_a.id,
          recipe_id: recipe.id,
          user_id: user.id,
          date: ~D[2026-07-02],
          slot: :lunch,
          servings: 2,
          is_cooked: true
        })

      {:ok, _uncooked_b} =
        PlanningRepo.schedule_meal(%{
          account_id: account_b.id,
          recipe_id: recipe.id,
          user_id: user.id,
          date: ~D[2026-07-01],
          slot: :lunch,
          servings: 2,
          is_cooked: false
        })

      list_a =
        PlanningRepo.list_uncooked_scheduled_meals_with_recipe_ingredients(
          account_a.id,
          ~D[2026-07-01],
          ~D[2026-07-31]
        )

      assert length(list_a) == 1
      [meal] = list_a
      assert meal.id == uncooked_a.id
      refute Enum.any?(list_a, &(&1.id == cooked_a.id))
      refute Enum.any?(list_a, &(&1.account_id == account_b.id))

      # Preloaded recipe -> recipe_ingredients -> ingredient chain.
      [recipe_ingredient] = meal.recipe.recipe_ingredients
      assert recipe_ingredient.ingredient.name == "Flour"
    end
  end

  describe "toggle_slot_favorite/1, is_slot_favorite?/4, list_slot_favorites/2 — account_id scoping" do
    test "toggling a slot favorite creates it, toggling again removes it" do
      account = insert_account("Favorite Toggle")
      user = insert_user_with_active_membership(account.id, "toggle@example.com", :owner)
      recipe = insert_recipe("Toggle Recipe")

      {:ok, meal} =
        PlanningRepo.schedule_meal(%{
          account_id: account.id,
          recipe_id: recipe.id,
          user_id: user.id,
          date: ~D[2026-07-01],
          slot: :lunch,
          servings: 2
        })

      attrs = %{
        account_id: account.id,
        user_id: user.id,
        date: ~D[2026-07-01],
        slot: "lunch",
        scheduled_meal_id: meal.id,
        recipe_id: recipe.id
      }

      refute PlanningRepo.is_slot_favorite?(account.id, user.id, ~D[2026-07-01], "lunch")

      assert {:ok, %{}} = PlanningRepo.toggle_slot_favorite(attrs)
      assert PlanningRepo.is_slot_favorite?(account.id, user.id, ~D[2026-07-01], "lunch")

      assert {:ok, %{status: :removed}} = PlanningRepo.toggle_slot_favorite(attrs)
      refute PlanningRepo.is_slot_favorite?(account.id, user.id, ~D[2026-07-01], "lunch")
    end

    test "is_slot_favorite?/4 does not leak a favorite across accounts" do
      account_a = insert_account("Slot Fav A")
      account_b = insert_account("Slot Fav B")

      user = insert_user_with_active_membership(account_a.id, "slotfav@example.com", :owner)
      _family_membership = insert_active_membership_for(account_b.id, user, :member)

      recipe = insert_recipe("Slot Fav Recipe")

      {:ok, meal} =
        PlanningRepo.schedule_meal(%{
          account_id: account_a.id,
          recipe_id: recipe.id,
          user_id: user.id,
          date: ~D[2026-07-01],
          slot: :dinner,
          servings: 2
        })

      assert {:ok, %{}} =
               PlanningRepo.toggle_slot_favorite(%{
                 account_id: account_a.id,
                 user_id: user.id,
                 date: ~D[2026-07-01],
                 slot: "dinner",
                 scheduled_meal_id: meal.id,
                 recipe_id: recipe.id
               })

      assert PlanningRepo.is_slot_favorite?(account_a.id, user.id, ~D[2026-07-01], "dinner")
      refute PlanningRepo.is_slot_favorite?(account_b.id, user.id, ~D[2026-07-01], "dinner")
    end

    test "list_slot_favorites/2 does not leak another account's favorites" do
      account_a = insert_account("List Fav A")
      account_b = insert_account("List Fav B")

      user = insert_user_with_active_membership(account_a.id, "listfav@example.com", :owner)
      _family_membership = insert_active_membership_for(account_b.id, user, :member)

      recipe = insert_recipe("List Fav Recipe")

      {:ok, meal_a} =
        PlanningRepo.schedule_meal(%{
          account_id: account_a.id,
          recipe_id: recipe.id,
          user_id: user.id,
          date: ~D[2026-07-01],
          slot: :breakfast,
          servings: 2
        })

      {:ok, meal_b} =
        PlanningRepo.schedule_meal(%{
          account_id: account_b.id,
          recipe_id: recipe.id,
          user_id: user.id,
          date: ~D[2026-07-01],
          slot: :breakfast,
          servings: 2
        })

      assert {:ok, %{}} =
               PlanningRepo.toggle_slot_favorite(%{
                 account_id: account_a.id,
                 user_id: user.id,
                 date: ~D[2026-07-01],
                 slot: "breakfast",
                 scheduled_meal_id: meal_a.id,
                 recipe_id: recipe.id
               })

      assert {:ok, %{}} =
               PlanningRepo.toggle_slot_favorite(%{
                 account_id: account_b.id,
                 user_id: user.id,
                 date: ~D[2026-07-01],
                 slot: "breakfast",
                 scheduled_meal_id: meal_b.id,
                 recipe_id: recipe.id
               })

      favorites_a = PlanningRepo.list_slot_favorites(account_a.id, user.id)

      assert length(favorites_a) == 1
      assert hd(favorites_a).account_id == account_a.id
      refute Enum.any?(favorites_a, &(&1.account_id == account_b.id))
    end
  end

  # ---- helpers --------------------------------------------------------------

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

  defp insert_recipe(name) do
    %Recipe{}
    |> Recipe.changeset(%{
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

  defp insert_ingredient(name) do
    %Ingredient{}
    |> Ingredient.changeset(%{name: name, category: :otros})
    |> Repo.insert!()
  end

  defp insert_recipe_ingredient(recipe, ingredient, quantity_milli) do
    %RecipeIngredient{}
    |> RecipeIngredient.changeset(%{
      recipe_id: recipe.id,
      ingredient_id: ingredient.id,
      quantity_milli: quantity_milli,
      unit: :g
    })
    |> Repo.insert!()
  end

  defp insert_proposal(account_id, user_id, label) do
    run =
      Repo.insert!(%MealPlannerApi.Persistence.Planning.PlanningGenerationRun{
        account_id: account_id,
        user_id: user_id,
        status: :completed,
        input_context: %{},
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })

    Repo.insert!(%MealPlannerApi.Persistence.Planning.PlanningProposal{
      generation_run_id: run.id,
      proposal_json: %{"title" => label},
      status: :pending
    })
  end
end
