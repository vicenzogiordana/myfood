defmodule MealPlannerApi.Data.PlanningCandidateParticipantsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Persistence.Accounts.UserExcludedIngredient
  alias MealPlannerApi.Persistence.Catalog.{Ingredient, Recipe, RecipeIngredient}
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  test "uses exclusions from every active account member, but not non-active members" do
    account = insert_account("Planning participants")
    owner = insert_member(account, "owner@example.com", :owner, :active)
    active_member = insert_member(account, "active@example.com", :member, :active)
    invited_member = insert_member(account, "invited@example.com", :member, :invited)
    suspended_member = insert_member(account, "suspended@example.com", :member, :suspended)

    active_ingredient = insert_ingredient("Active exclusion")
    invited_ingredient = insert_ingredient("Invited exclusion")
    suspended_ingredient = insert_ingredient("Suspended exclusion")
    allowed_ingredient = insert_ingredient("Allowed ingredient")

    active_recipe = insert_recipe("Active excluded recipe", active_ingredient)
    invited_recipe = insert_recipe("Invited allowed recipe", invited_ingredient)
    suspended_recipe = insert_recipe("Suspended allowed recipe", suspended_ingredient)
    allowed_recipe = insert_recipe("Allowed recipe", allowed_ingredient)

    exclude(active_member, active_ingredient)
    exclude(invited_member, invited_ingredient)
    exclude(suspended_member, suspended_ingredient)

    candidate_ids = PlanningRepo.candidate_recipe_ids_for_slots(account.id, [owner.id], ["lunch"])

    refute active_recipe.id in candidate_ids
    assert invited_recipe.id in candidate_ids
    assert suspended_recipe.id in candidate_ids
    assert allowed_recipe.id in candidate_ids
  end

  defp insert_account(name) do
    plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

    %PersistenceAccount{}
    |> PersistenceAccount.changeset(%{
      name: name,
      plan: :family_4,
      default_budget_cents: 0,
      subscription_plan_id: plan.id
    })
    |> Repo.insert!()
  end

  defp insert_member(account, email, role, status) do
    user =
      %PersistenceUser{}
      |> PersistenceUser.changeset(%{email: email, name: email, role: role})
      |> Repo.insert!()

    %AccountMembership{}
    |> AccountMembership.changeset(%{
      account_id: account.id,
      user_id: user.id,
      role: role,
      status: status,
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

  defp insert_recipe(name, ingredient) do
    recipe =
      %Recipe{}
      |> Recipe.changeset(%{
        name: name,
        description: "Test recipe",
        servings: 2,
        cooking_time_minutes: 30,
        suitable_for_slots: ["lunch"],
        source: :user_created
      })
      |> Repo.insert!()

    %RecipeIngredient{}
    |> RecipeIngredient.changeset(%{
      recipe_id: recipe.id,
      ingredient_id: ingredient.id,
      quantity_milli: 100,
      unit: :g
    })
    |> Repo.insert!()

    recipe
  end

  defp exclude(user, ingredient) do
    %UserExcludedIngredient{}
    |> UserExcludedIngredient.changeset(%{
      user_id: user.id,
      ingredient_id: ingredient.id,
      reason: :allergy
    })
    |> Repo.insert!()
  end
end
