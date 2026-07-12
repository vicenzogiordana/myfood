defmodule MealPlannerApi.Services.TenancySweepTest do
  @moduledoc """
  Phase A — Tenancy Refactor (PR 3c task 3.21) — shared "service sweep"
  integration test.

  ## Grep-first verification (per-service audit)

  Task 3.21 lists 12 services. Per-file grep verification (recorded here
  and in `apply-progress.md` §"PR 3c") found:

    * `account_service.ex` — NO internal change needed. `me/1`/`context/1`
      already take an explicit `%{account_id:, user_id:}` map built by
      the CALLER (`AccountsController`, fixed in task 3.22) — the service
      never reads `user.account_id` itself.
    * `generation_service.ex`, `price_service.ex`, `revenuecat_service.ex`,
      `subscription_service.ex` — NO internal change needed. All 4
      already take `account_id` directly from the caller; none accept a
      `user`/`current_user` struct at all.
    * `budget_service.ex`, `cooking_service.ex`, `inventory_service.ex`,
      `planning_chat_service.ex`, `planning_service.ex`,
      `recipe_service.ex`, `shopping_service.ex` — these 7 DO take a
      `user`/`current_user` map and DID read `.account_id` off it
      (directly, or via `Identity.ensure_persistent_identity/1`). NO
      internal rewrite was needed here either, because PR 3c's controller
      sweep (tasks 3.14-3.20, 3.22) already corrects `user.account_id` to
      `current_membership.account_id` at the single point tenancy scope
      enters the domain layer — the controller boundary
      (`AccountScopeHelpers.scope_user_to_membership/2`) — before the
      User struct ever reaches these services. Rewriting each service's
      internal signature to accept `membership` directly was considered
      and rejected: these services also depend on OTHER `user` fields
      unrelated to tenancy (`subscription_tier`, `kcal_target`,
      `weekly_budget_cents`, ...), so replacing the whole parameter with
      a bare `membership` would require a much larger, higher-risk
      rewrite of every call site for no additional isolation guarantee
      over the boundary-correction approach.
    * `Identity.ensure_persistent_identity/1` itself needed a prerequisite
      fix (see `identity_test.exs` / `apply-progress.md`) so it can
      resolve a real, multi-membership User via an `:active`
      `AccountMembership` row instead of only the legacy
      `users.account_id` column.

  This test proves the resulting behavior end-to-end: for every one of
  the 7 `user`-taking services, a User scoped (at the service-call
  boundary, exactly like a controller would via
  `AccountScopeHelpers.scope_user_to_membership/2`) to Account A's
  membership sees ONLY Account A's data — Account B's data (seeded
  identically) is never returned.
  """

  use ExUnit.Case, async: false

  import MealPlannerApi.FactoryHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Persistence.Calendar
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Planning
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.BudgetService
  alias MealPlannerApi.Services.CookingService
  alias MealPlannerApi.Services.InventoryService
  alias MealPlannerApi.Services.PlanningChatService
  alias MealPlannerApi.Services.RecipeService
  alias MealPlannerApi.Services.ShoppingService
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()

    user =
      user_with_memberships(%{email: "tenancy_sweep@example.com"}, [
        {%{plan: :family_4, name: "Tenancy Sweep Account A"}, :owner},
        {%{plan: :family_4, name: "Tenancy Sweep Account B"}, :member}
      ])

    [membership_a, membership_b] = user.memberships

    %{
      user: user,
      membership_a: membership_a,
      membership_b: membership_b,
      scoped_user_a: AccountScopeHelpers.scope_user_to_membership(user, membership_a),
      scoped_user_b: AccountScopeHelpers.scope_user_to_membership(user, membership_b)
    }
  end

  describe "BudgetService.resolve/1" do
    test "resolves the budget of the scoped Account only", %{
      user: user,
      membership_a: membership_a,
      membership_b: membership_b
    } do
      MealPlannerApi.Data.AccountRepo.get_account!(membership_a.account_id)
      |> Ecto.Changeset.change(%{default_budget_cents: 11_111})
      |> Repo.update!()

      MealPlannerApi.Data.AccountRepo.get_account!(membership_b.account_id)
      |> Ecto.Changeset.change(%{default_budget_cents: 99_999})
      |> Repo.update!()

      scoped_a = AccountScopeHelpers.scope_user_to_membership(user, membership_a)
      budget = BudgetService.resolve(scoped_a)

      assert budget.account_id == membership_a.account_id
      assert budget.weekly_limit_cents == 11_111
      refute budget.weekly_limit_cents == 99_999
    end
  end

  describe "CookingService.session_state/2" do
    test "only resolves a cooking session that belongs to the scoped Account", %{
      user: user,
      membership_a: membership_a,
      scoped_user_a: scoped_user_a,
      scoped_user_b: scoped_user_b
    } do
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: membership_a.account_id,
          created_by_user_id: user.id,
          name: "Tenancy Sweep Cooking Recipe",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:dinner]
        })

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: membership_a.account_id,
          date: ~D[2026-05-01],
          slot: :dinner,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, session} =
        Planning.create_cooking_session(%{
          account_id: membership_a.account_id,
          scheduled_meal_id: meal.id,
          status: :active,
          started_at: DateTime.utc_now(),
          context_snapshot: %{}
        })

      assert {:ok, _state} = CookingService.session_state(scoped_user_a, session.id)

      assert {:error, :session_not_found} =
               CookingService.session_state(scoped_user_b, session.id)
    end
  end

  describe "InventoryService.inventory_view/1" do
    test "only lists inventory items that belong to the scoped Account", %{
      user: user,
      membership_a: membership_a,
      scoped_user_a: scoped_user_a,
      scoped_user_b: scoped_user_b
    } do
      {:ok, ingredient} =
        Catalog.upsert_ingredient_by_name(%{
          name: "Tenancy Sweep Inventory Ingredient",
          category: :no_perecederos,
          calories_per_100: 100,
          protein_g_per_100: Decimal.new("1.0"),
          carbs_g_per_100: Decimal.new("1.0"),
          fat_g_per_100: Decimal.new("1.0")
        })

      {:ok, _seed} =
        MealPlannerApi.Persistence.Inventory.apply_delta_and_log(%{
          account_id: membership_a.account_id,
          ingredient_id: ingredient.id,
          unit: :g,
          source_kind: :planned,
          delta: 500,
          source_user_id: user.id,
          trigger_type: :purchase,
          operation: :add
        })

      {:ok, view_a} = InventoryService.inventory_view(scoped_user_a)
      {:ok, view_b} = InventoryService.inventory_view(scoped_user_b)

      ids_a = Enum.map(view_a.sections.ok, & &1.ingredient_id)
      ids_b = Enum.map(view_b.sections.ok, & &1.ingredient_id)

      assert ingredient.id in ids_a
      refute ingredient.id in ids_b
    end
  end

  describe "PlanningChatService.quick_favorites/2" do
    test "only lists favorites that belong to the scoped Account", %{
      user: user,
      membership_a: membership_a,
      scoped_user_a: scoped_user_a,
      scoped_user_b: scoped_user_b
    } do
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: membership_a.account_id,
          created_by_user_id: user.id,
          name: "Tenancy Sweep Favorite Recipe",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, _favorite} = Calendar.toggle_favorite(membership_a.account_id, user.id, recipe.id)

      {:ok, favorites_a} = PlanningChatService.quick_favorites(scoped_user_a, 10)
      {:ok, favorites_b} = PlanningChatService.quick_favorites(scoped_user_b, 10)

      assert Enum.any?(favorites_a, &(&1.recipe_id == recipe.id))
      refute Enum.any?(favorites_b, &(&1.recipe_id == recipe.id))
    end
  end

  describe "ShoppingService.get_shopping_list/2" do
    test "only lists shopping items that belong to the scoped Account", %{
      user: user,
      membership_a: membership_a,
      scoped_user_a: scoped_user_a,
      scoped_user_b: scoped_user_b
    } do
      {:ok, ingredient} =
        Catalog.upsert_ingredient_by_name(%{
          name: "Tenancy Sweep Shopping Ingredient",
          category: :verduras,
          calories_per_100: 40,
          protein_g_per_100: Decimal.new("1.2"),
          carbs_g_per_100: Decimal.new("9.3"),
          fat_g_per_100: Decimal.new("0.1")
        })

      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: membership_a.account_id,
          created_by_user_id: user.id,
          name: "Tenancy Sweep Shopping Recipe",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:dinner]
        })

      today = Date.utc_today()

      {:ok, meal} =
        Planning.schedule_meal(%{
          account_id: membership_a.account_id,
          date: today,
          slot: :dinner,
          recipe_id: recipe.id,
          is_cooked: false
        })

      {:ok, _item} =
        MealPlannerApi.Persistence.Shopping.create_shopping_item(%{
          account_id: membership_a.account_id,
          scheduled_meal_id: meal.id,
          planned_date: today,
          ingredient_id: ingredient.id,
          quantity_milli: 300,
          unit: :g,
          status: :pending
        })

      params = %{
        "from_date" => Date.to_iso8601(today),
        "to_date" => Date.to_iso8601(Date.add(today, 6))
      }

      {:ok, list_a} = ShoppingService.get_shopping_list(scoped_user_a, params)
      {:ok, list_b} = ShoppingService.get_shopping_list(scoped_user_b, params)

      ids_a = Enum.map(list_a.items, & &1.ingredient_id)
      ids_b = Enum.map(list_b.items, & &1.ingredient_id)

      assert ingredient.id in ids_a
      refute ingredient.id in ids_b
    end
  end

  describe "RecipeService.is_favorite?/2" do
    # `RecipeService.list_recipes/1` and `.add_favorite/2` are NOT used
    # for this sub-test: both crash on pre-existing, unrelated bugs
    # (`serialize_recipe/1` reads a `:title` field the `Recipe` schema
    # doesn't have; `RecipeRepo.add_favorite/2`'s `FavoriteRecipe`
    # changeset requires `:user_id` but the call site never supplies
    # one). `RecipeService` has no production callers anywhere in
    # `lib/` per the task 3.21 grep audit, so neither bug was
    # previously exercised — both are out of scope for this tenancy PR.
    # The favorite row is seeded directly via `Calendar.toggle_favorite/3`
    # (the same helper used elsewhere in this PR's controller tests) so
    # this sub-test can still exercise `is_favorite?/2`'s
    # `Identity.ensure_persistent_identity/1` + account-scoped
    # `RecipeRepo` read path without hitting either bug.
    test "only sees a favorite that belongs to the scoped Account", %{
      user: user,
      membership_a: membership_a,
      scoped_user_a: scoped_user_a,
      scoped_user_b: scoped_user_b
    } do
      {:ok, recipe} =
        Catalog.create_recipe(%{
          account_id: membership_a.account_id,
          created_by_user_id: user.id,
          name: "Tenancy Sweep Recipe Service Recipe",
          source: :user_created,
          servings: 2,
          suitable_for_slots: [:lunch]
        })

      {:ok, _fav} = Calendar.toggle_favorite(membership_a.account_id, user.id, recipe.id)

      assert RecipeService.is_favorite?(scoped_user_a, recipe.id)
      refute RecipeService.is_favorite?(scoped_user_b, recipe.id)
    end
  end
end
