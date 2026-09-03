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

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Catalog.Ingredient
  alias MealPlannerApi.Persistence.Catalog.Recipe
  alias MealPlannerApi.Persistence.Catalog.RecipeIngredient
  alias MealPlannerApi.Persistence.Accounts.UserExcludedIngredient
  alias MealPlannerApi.Persistence.Planning.PlanningException
  alias MealPlannerApi.Persistence.Planning.PlanningMessage
  alias MealPlannerApi.Persistence.Planning.PlanningSession
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

  describe "candidate_recipe_ids_for_slots/3 — participating member exclusions" do
    test "excludes recipes containing an ingredient excluded by any participating member" do
      account = insert_account("Candidate Filtering")

      owner =
        insert_user_with_active_membership(account.id, "candidate-owner@example.com", :owner)

      member =
        insert_user_with_active_membership(account.id, "candidate-member@example.com", :member)

      excluded_ingredient = insert_ingredient("Excluded Candidate Ingredient")
      allowed_ingredient = insert_ingredient("Allowed Candidate Ingredient")
      blocked_recipe = insert_recipe("Blocked Candidate Recipe")
      allowed_recipe = insert_recipe("Allowed Candidate Recipe")

      insert_recipe_ingredient(blocked_recipe, excluded_ingredient, 100)
      insert_recipe_ingredient(allowed_recipe, allowed_ingredient, 100)

      %UserExcludedIngredient{}
      |> UserExcludedIngredient.changeset(%{
        user_id: member.id,
        ingredient_id: excluded_ingredient.id,
        reason: :allergy
      })
      |> Repo.insert!()

      candidate_ids =
        PlanningRepo.candidate_recipe_ids_for_slots(account.id, [owner.id, member.id], ["lunch"])

      assert allowed_recipe.id in candidate_ids
      refute blocked_recipe.id in candidate_ids
    end
  end

  # =========================================================================
  # PR2 — ephemeral-planning-sessions: PlanningRepo lifecycle CRUD
  # =========================================================================

  describe "create_session/2 — writes one :active row per (account, range)" do
    test "happy path: inserts a planning session and returns {:ok, %PlanningSession{}} with status :active" do
      account = insert_account("Create Session Happy")
      owner = insert_user_with_active_membership(account.id, "create-happy@example.com", :owner)

      lease = DateTime.add(DateTime.utc_now(), 120, :second)

      assert {:ok, %PlanningSession{} = session} =
               PlanningRepo.create_session(account.id, %{
                 range_from: ~D[2026-03-01],
                 range_to: ~D[2026-03-08],
                 lock_owner_user_id: owner.id,
                 lock_owner_membership_id: owner_membership_id(account.id, owner.id),
                 lease_expires_at: lease
               })

      assert session.status == :active
      assert session.account_id == account.id
      assert session.range_from == ~D[2026-03-01]
      assert session.range_to == ~D[2026-03-08]
      assert session.lock_owner_user_id == owner.id
      assert session.started_at != nil

      # The row is actually in the DB.
      fetched = Repo.get!(PlanningSession, session.id)
      assert fetched.status == :active
      assert fetched.account_id == account.id
    end

    test "overlapping active ranges on the same account return {:error, :overlapping_range}" do
      account = insert_account("Create Session Overlap")
      owner = insert_user_with_active_membership(account.id, "create-overlap@example.com", :owner)

      membership_id = owner_membership_id(account.id, owner.id)
      lease = DateTime.add(DateTime.utc_now(), 120, :second)

      assert {:ok, _first} =
               PlanningRepo.create_session(account.id, %{
                 range_from: ~D[2026-03-01],
                 range_to: ~D[2026-03-08],
                 lock_owner_user_id: owner.id,
                 lock_owner_membership_id: membership_id,
                 lease_expires_at: lease
               })

      assert {:error, :overlapping_range} =
               PlanningRepo.create_session(account.id, %{
                 range_from: ~D[2026-03-05],
                 range_to: ~D[2026-03-12],
                 lock_owner_user_id: owner.id,
                 lock_owner_membership_id: membership_id,
                 lease_expires_at: lease
               })

      # Only the first session row exists on the account.
      count =
        Repo.one!(
          from(s in PlanningSession,
            where: s.account_id == ^account.id,
            select: count(s.id)
          )
        )

      assert count == 1
    end

    test "different accounts can hold overlapping active ranges (EXCLUDE is per-account)" do
      account_a = insert_account("Create Session Per-Account A")
      account_b = insert_account("Create Session Per-Account B")

      owner_a =
        insert_user_with_active_membership(account_a.id, "create-per-acct-a@example.com", :owner)

      owner_b =
        insert_user_with_active_membership(account_b.id, "create-per-acct-b@example.com", :owner)

      lease = DateTime.add(DateTime.utc_now(), 120, :second)

      assert {:ok, session_a} =
               PlanningRepo.create_session(account_a.id, %{
                 range_from: ~D[2026-03-01],
                 range_to: ~D[2026-03-08],
                 lock_owner_user_id: owner_a.id,
                 lock_owner_membership_id: owner_membership_id(account_a.id, owner_a.id),
                 lease_expires_at: lease
               })

      assert {:ok, session_b} =
               PlanningRepo.create_session(account_b.id, %{
                 range_from: ~D[2026-03-01],
                 range_to: ~D[2026-03-08],
                 lock_owner_user_id: owner_b.id,
                 lock_owner_membership_id: owner_membership_id(account_b.id, owner_b.id),
                 lease_expires_at: lease
               })

      assert session_a.account_id != session_b.account_id
      assert session_a.id != session_b.id
    end
  end

  describe "cancel_session/4 — owner-scoped cancel, hard-deletes children" do
    test "the session owner cancels their own session: status -> :cancelled, children hard-deleted" do
      account = insert_account("Cancel Owner")
      owner = insert_user_with_active_membership(account.id, "cancel-owner@example.com", :owner)

      membership_id = owner_membership_id(account.id, owner.id)
      lease = DateTime.add(DateTime.utc_now(), 120, :second)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-04-01],
          range_to: ~D[2026-04-08],
          lock_owner_user_id: owner.id,
          lock_owner_membership_id: membership_id,
          lease_expires_at: lease
        })

      # Seed children so we can prove they're hard-deleted.
      seed_children!(session.id, account.id)

      {messages_before, exceptions_before} = child_counts(session.id)
      assert messages_before == 1
      assert exceptions_before == 1

      assert {:ok, %PlanningSession{} = cancelled} =
               PlanningRepo.cancel_session(
                 account.id,
                 session.id,
                 membership_id,
                 false
               )

      assert cancelled.id == session.id
      assert cancelled.status == :cancelled
      assert cancelled.terminal_at != nil

      # Session row remains queryable for audit.
      assert Repo.get!(PlanningSession, session.id).status == :cancelled

      # Children hard-deleted.
      {messages_after, exceptions_after} = child_counts(session.id)
      assert messages_after == 0
      assert exceptions_after == 0
    end

    test "a non-owner peer cannot cancel someone else's session: returns {:error, :forbidden}" do
      account = insert_account("Cancel Peer Forbidden")

      owner =
        insert_user_with_active_membership(account.id, "cancel-peer-owner@example.com", :owner)

      peer =
        insert_user_with_active_membership(account.id, "cancel-peer-peer@example.com", :member)

      owner_membership = owner_membership_id(account.id, owner.id)
      peer_membership = owner_membership_id(account.id, peer.id)
      lease = DateTime.add(DateTime.utc_now(), 120, :second)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-04-01],
          range_to: ~D[2026-04-08],
          lock_owner_user_id: owner.id,
          lock_owner_membership_id: owner_membership,
          lease_expires_at: lease
        })

      assert {:error, :forbidden} =
               PlanningRepo.cancel_session(
                 account.id,
                 session.id,
                 peer_membership,
                 false
               )

      # Session still active, no children deleted.
      assert Repo.get!(PlanningSession, session.id).status == :active
    end

    test "account :owner can cancel a peer's session (peer_membership, true flag)" do
      account = insert_account("Cancel Account Owner")

      owner =
        insert_user_with_active_membership(account.id, "cancel-acct-owner@example.com", :owner)

      peer =
        insert_user_with_active_membership(account.id, "cancel-acct-peer@example.com", :member)

      owner_membership = owner_membership_id(account.id, owner.id)
      peer_membership = owner_membership_id(account.id, peer.id)
      lease = DateTime.add(DateTime.utc_now(), 120, :second)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-04-01],
          range_to: ~D[2026-04-08],
          lock_owner_user_id: peer.id,
          lock_owner_membership_id: peer_membership,
          lease_expires_at: lease
        })

      seed_children!(session.id, account.id)

      assert {:ok, %PlanningSession{} = cancelled} =
               PlanningRepo.cancel_session(
                 account.id,
                 session.id,
                 owner_membership,
                 true
               )

      assert cancelled.status == :cancelled

      {messages_after, exceptions_after} = child_counts(session.id)
      assert messages_after == 0
      assert exceptions_after == 0
    end

    test "cancelling a session that is already terminal returns {:error, :not_active}" do
      account = insert_account("Cancel Terminal")

      owner =
        insert_user_with_active_membership(account.id, "cancel-terminal@example.com", :owner)

      membership_id = owner_membership_id(account.id, owner.id)
      lease = DateTime.add(DateTime.utc_now(), 120, :second)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-04-01],
          range_to: ~D[2026-04-08],
          lock_owner_user_id: owner.id,
          lock_owner_membership_id: membership_id,
          lease_expires_at: lease
        })

      assert {:ok, %PlanningSession{}} =
               PlanningRepo.cancel_session(account.id, session.id, membership_id, false)

      assert {:error, :not_active} =
               PlanningRepo.cancel_session(account.id, session.id, membership_id, false)
    end

    test "cancelling a session that does not exist returns {:error, :not_active}" do
      account = insert_account("Cancel Not Found")
      owner = insert_user_with_active_membership(account.id, "cancel-missing@example.com", :owner)

      missing_id = Ecto.UUID.generate()
      membership_id = owner_membership_id(account.id, owner.id)

      # `fetch_active_session/2` runs before the actor authorization; a
      # missing session id is treated as "no active session" — same
      # outcome as a terminal one, but without the auth check.
      assert {:error, :not_active} =
               PlanningRepo.cancel_session(account.id, missing_id, membership_id, true)
    end
  end

  describe "expire_session/2 — sweeper-driven transition to :expired" do
    test "an active session transitions to :expired and children are hard-deleted" do
      account = insert_account("Expire Active")
      owner = insert_user_with_active_membership(account.id, "expire-active@example.com", :owner)

      membership_id = owner_membership_id(account.id, owner.id)
      lease = DateTime.add(DateTime.utc_now(), 120, :second)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-05-01],
          range_to: ~D[2026-05-08],
          lock_owner_user_id: owner.id,
          lock_owner_membership_id: membership_id,
          lease_expires_at: lease
        })

      seed_children!(session.id, account.id)

      assert {:ok, %PlanningSession{} = expired} =
               PlanningRepo.expire_session(account.id, session.id)

      assert expired.status == :expired
      assert expired.terminal_at != nil

      {messages_after, exceptions_after} = child_counts(session.id)
      assert messages_after == 0
      assert exceptions_after == 0
    end

    test "expiring a session that is already terminal returns {:error, :not_active}" do
      account = insert_account("Expire Terminal")

      owner =
        insert_user_with_active_membership(account.id, "expire-terminal@example.com", :owner)

      membership_id = owner_membership_id(account.id, owner.id)
      lease = DateTime.add(DateTime.utc_now(), 120, :second)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-05-01],
          range_to: ~D[2026-05-08],
          lock_owner_user_id: owner.id,
          lock_owner_membership_id: membership_id,
          lease_expires_at: lease
        })

      assert {:ok, %PlanningSession{}} = PlanningRepo.expire_session(account.id, session.id)
      assert {:error, :not_active} = PlanningRepo.expire_session(account.id, session.id)
    end
  end

  describe "mark_lost_lock/2 — owner-process-death transition to :lost_lock" do
    test "an active session transitions to :lost_lock and children are hard-deleted" do
      account = insert_account("Lost Lock Active")

      owner =
        insert_user_with_active_membership(account.id, "lost-lock-active@example.com", :owner)

      membership_id = owner_membership_id(account.id, owner.id)
      lease = DateTime.add(DateTime.utc_now(), 120, :second)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-06-01],
          range_to: ~D[2026-06-08],
          lock_owner_user_id: owner.id,
          lock_owner_membership_id: membership_id,
          lease_expires_at: lease
        })

      seed_children!(session.id, account.id)

      assert {:ok, %PlanningSession{} = lost_lock} =
               PlanningRepo.mark_lost_lock(account.id, session.id)

      assert lost_lock.status == :lost_lock
      assert lost_lock.terminal_at != nil

      {messages_after, exceptions_after} = child_counts(session.id)
      assert messages_after == 0
      assert exceptions_after == 0
    end

    test "marking lost_lock on a session that is already terminal returns {:error, :not_active}" do
      account = insert_account("Lost Lock Terminal")

      owner =
        insert_user_with_active_membership(account.id, "lost-lock-terminal@example.com", :owner)

      membership_id = owner_membership_id(account.id, owner.id)
      lease = DateTime.add(DateTime.utc_now(), 120, :second)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-06-01],
          range_to: ~D[2026-06-08],
          lock_owner_user_id: owner.id,
          lock_owner_membership_id: membership_id,
          lease_expires_at: lease
        })

      assert {:ok, %PlanningSession{}} = PlanningRepo.mark_lost_lock(account.id, session.id)
      assert {:error, :not_active} = PlanningRepo.mark_lost_lock(account.id, session.id)
    end
  end

  describe "mark_committed/2 — confirm_proposal transition to :committed, children PRESERVED" do
    test "an active session transitions to :committed and children are PRESERVED (audit trail)" do
      account = insert_account("Commit Active")
      owner = insert_user_with_active_membership(account.id, "commit-active@example.com", :owner)

      membership_id = owner_membership_id(account.id, owner.id)
      lease = DateTime.add(DateTime.utc_now(), 120, :second)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-07-01],
          range_to: ~D[2026-07-08],
          lock_owner_user_id: owner.id,
          lock_owner_membership_id: membership_id,
          lease_expires_at: lease
        })

      seed_children!(session.id, account.id)

      assert {:ok, %PlanningSession{} = committed} =
               PlanningRepo.mark_committed(account.id, session.id)

      assert committed.status == :committed
      assert committed.terminal_at != nil

      # CRITICAL: children are NOT hard-deleted on :committed — only on
      # :cancelled / :expired / :lost_lock per spec §"Audit trail after
      # terminal transition".
      {messages_after, exceptions_after} = child_counts(session.id)
      assert messages_after == 1
      assert exceptions_after == 1
    end

    test "committing a session that is already terminal returns {:error, :not_active}" do
      account = insert_account("Commit Terminal")

      owner =
        insert_user_with_active_membership(account.id, "commit-terminal@example.com", :owner)

      membership_id = owner_membership_id(account.id, owner.id)
      lease = DateTime.add(DateTime.utc_now(), 120, :second)

      {:ok, session} =
        PlanningRepo.create_session(account.id, %{
          range_from: ~D[2026-07-01],
          range_to: ~D[2026-07-08],
          lock_owner_user_id: owner.id,
          lock_owner_membership_id: membership_id,
          lease_expires_at: lease
        })

      assert {:ok, %PlanningSession{}} = PlanningRepo.mark_committed(account.id, session.id)
      assert {:error, :not_active} = PlanningRepo.mark_committed(account.id, session.id)
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

  # ---- PR2 helpers --------------------------------------------------------

  defp owner_membership_id(account_id, user_id) do
    membership =
      Repo.one!(
        from(m in AccountMembership,
          where: m.account_id == ^account_id and m.user_id == ^user_id and m.status == :active
        )
      )

    membership.id
  end

  defp seed_children!(session_id, account_id) do
    Repo.insert!(%PlanningMessage{
      account_id: account_id,
      session_id: session_id,
      role: :user,
      content: "hello"
    })

    Repo.insert!(%PlanningException{
      account_id: account_id,
      session_id: session_id,
      kind: "test",
      note: "seeded"
    })
  end

  defp child_counts(session_id) do
    messages =
      Repo.one!(
        from(m in PlanningMessage, where: m.session_id == ^session_id, select: count(m.id))
      )

    exceptions =
      Repo.one!(
        from(e in PlanningException, where: e.session_id == ^session_id, select: count(e.id))
      )

    {messages, exceptions}
  end
end
